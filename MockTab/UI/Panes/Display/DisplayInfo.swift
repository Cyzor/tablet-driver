// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import TabletKit

// MARK: - DisplayInfo

struct DisplayInfo {
    var id: CGDirectDisplayID
    /// 1-based index into CGGetActiveDisplayList — the value stored in targetDisplayIndex.
    var listIndex: Int
    var bounds: CGRect  // in CGDisplayBounds / Quartz coordinates
    var name: String  // localised device name if available
    var resolution: String  // e.g. "2560×1440"
    /// Desktop image thumbnail, or nil when none could be loaded.
    ///
    /// Known inaccuracy: since the Wallpaper settings pane replaced Desktop &
    /// Screen Saver, `NSWorkspace.desktopImageURL(for:)` only reports still
    /// images set the old way. Solid colors, aerials, dynamic wallpapers and
    /// per-Space choices all live in the private `com.apple.wallpaper` store,
    /// and the API returns `/System/Library/CoreServices/DefaultDesktop.heic`
    /// instead — so those setups show a stock image here rather than what is
    /// actually on screen. Reading the private store or screenshotting the
    /// desktop (Screen Recording permission) are the only alternatives, and
    /// neither is worth it for a decorative thumbnail. Revisit only if Apple
    /// ships a supported query.
    var wallpaper: NSImage?

    var pickerLabel: String { "\(name) (\(resolution))" }

    /// Fallback label when `name` doesn't fit a crowded thumbnail (e.g. "Pen" from "Pen Display24").
    var firstWord: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// Widest label — full name, first word, or bare index — that fits `maxWidth`.
    enum LabelTier { case full, firstWord, index }

    func labelTier(fitting maxWidth: CGFloat, font: NSFont) -> LabelTier {
        func width(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        if width(name) <= maxWidth { return .full }
        if width(firstWord) <= maxWidth { return .firstWord }
        return .index
    }

    /// Returns all active displays sorted by screen position (left→right, top→bottom),
    /// matching the arrangement shown in System Settings > Displays.
    static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        var screenMap: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID
            {
                screenMap[num] = screen
            }
        }

        let unsorted = ids.enumerated().map { index, id -> DisplayInfo in
            let name = screenMap[id]?.localizedName ?? "Display \(index + 1)"
            let w = Int(CGDisplayPixelsWide(id))
            let h = Int(CGDisplayPixelsHigh(id))
            let wallpaper: NSImage? = screenMap[id].flatMap { screen in
                NSWorkspace.shared.desktopImageURL(for: screen)
                    .flatMap { Self.cachedThumbnail(from: $0, maxEdge: 640) }
            }
            return DisplayInfo(
                id: id, listIndex: index + 1,
                bounds: CGDisplayBounds(id),
                name: name, resolution: "\(w)×\(h)",
                wallpaper: wallpaper)
        }

        // Sort left-to-right, then top-to-bottom — matches System Settings Displays arrangement.
        return unsorted.sorted {
            if abs($0.bounds.minX - $1.bounds.minX) > 1 { return $0.bounds.minX < $1.bounds.minX }
            return $0.bounds.minY < $1.bounds.minY
        }
    }

    /// Keyed by desktop-image URL so re-running `all()` skips decoding
    /// thumbnails for displays whose wallpaper hasn't changed.
    private static var thumbnailCache: [URL: NSImage] = [:]

    private static func cachedThumbnail(from url: URL, maxEdge: CGFloat) -> NSImage? {
        if let cached = thumbnailCache[url] { return cached }
        guard let thumbnail = loadThumbnail(from: url, maxEdge: maxEdge) else { return nil }
        thumbnailCache[url] = thumbnail
        return thumbnail
    }

    private static func loadThumbnail(from url: URL, maxEdge: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        else { return nil }
        let toned = tonedDown(cg) ?? cg
        return NSImage(cgImage: toned, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Desaturates and flattens contrast so the thumbnail reads as a muted
    /// backdrop rather than competing with the crop chrome drawn over it —
    /// most setups resolve to Apple's default wallpaper here (see
    /// `wallpaper`'s doc comment), which is busy and heavily saturated at
    /// full strength. `nil` on failure; caller falls back to the untouched
    /// thumbnail.
    ///
    /// Plain pixel math rather than Core Image: a `CIContext` loads Metal
    /// kernel archives worth ~130 MB, a spike on every settings window open.
    private static func tonedDown(_ cg: CGImage) -> CGImage? {
        let width = cg.width, height = cg.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        let saturation: Float = 0.35, contrast: Float = 0.85
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let r = Float(pixels[i]), g = Float(pixels[i + 1]), b = Float(pixels[i + 2])
            let a = Float(pixels[i + 3])
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            // Premultiplied, so mid-gray and the clamp scale with alpha.
            func tone(_ c: Float) -> UInt8 {
                let adjusted = (luma + saturation * (c - luma) - a / 2) * contrast + a / 2
                return UInt8(min(max(adjusted, 0), a).rounded())
            }
            pixels[i] = tone(r)
            pixels[i + 1] = tone(g)
            pixels[i + 2] = tone(b)
        }
        return ctx.makeImage()
    }
}
