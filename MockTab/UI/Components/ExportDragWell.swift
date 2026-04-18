import SwiftUI
import AppKit

/// An 80x80 pt well that supports both drag-out (export) and drag-in (import).
/// Drag the document icon out to Finder to save a backup.
/// Drag a .json file onto it to trigger an import.
struct ExportDragWell: NSViewRepresentable {
    var generateJSON: () -> Data?
    var onImport: (Data) -> Void

    func makeNSView(context: Context) -> ExportWellNSView {
        let v = ExportWellNSView()
        v.generateJSON = generateJSON
        v.onImport = onImport
        return v
    }

    func updateNSView(_ nsView: ExportWellNSView, context: Context) {
        nsView.generateJSON = generateJSON
        nsView.onImport = onImport
    }
}

@MainActor
final class ExportWellNSView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var generateJSON: (() -> Data?)?
    var onImport: ((Data) -> Void)?

    private let iconLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private var isDropTarget = false {
        didSet { updateDropAppearance() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupLayers()
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("public.file-url")])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupLayers() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        // Dashed border
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.separatorColor.cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.lineDashPattern = [6, 4]
        layer?.addSublayer(borderLayer)

        // Document icon
        updateIconSymbol(receiving: false)
        layer?.addSublayer(iconLayer)
    }

    private func updateIconSymbol(receiving: Bool) {
        let name = receiving ? "doc.badge.arrow.down" : "doc.badge.arrow.up"
        let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        {
            iconLayer.contents = img
            iconLayer.contentsGravity = .resizeAspect
        }
    }

    private func updateDropAppearance() {
        let accent = NSColor.controlAccentColor.cgColor
        let separator = NSColor.separatorColor.cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        borderLayer.strokeColor = isDropTarget ? accent : separator
        borderLayer.lineWidth = isDropTarget ? 2.0 : 1.5
        CATransaction.commit()
        updateIconSymbol(receiving: isDropTarget)
    }

    override func layout() {
        super.layout()
        let r = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        borderLayer.path = path.cgPath
        borderLayer.frame = bounds
        let size: CGFloat = 36
        iconLayer.frame = CGRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        if !isDropTarget {
            borderLayer.strokeColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard jsonURL(from: sender) != nil else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard jsonURL(from: sender) != nil else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let url = jsonURL(from: sender), let data = try? Data(contentsOf: url) else {
            return false
        }
        onImport?(data)
        return true
    }

    private func jsonURL(from info: NSDraggingInfo) -> URL? {
        guard
            let urls = info.draggingPasteboard
                .readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
            let url = urls.first,
            url.pathExtension.lowercased() == "json"
        else { return nil }
        return url
    }

    // MARK: - Drag source

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    override func mouseDown(with event: NSEvent) {
        let provider = NSFilePromiseProvider(fileType: "public.json", delegate: self)
        let item = NSDraggingItem(pasteboardWriter: provider)

        // Render the symbol onto a square canvas at its natural size so the
        // dragging item doesn't stretch it to fill an arbitrary frame rect.
        let canvasSize: CGFloat = 44
        let canvas = NSSize(width: canvasSize, height: canvasSize)
        let ghost = NSImage(size: canvas, flipped: false) { rect in
            let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
            guard
                let sym = NSImage(
                    systemSymbolName: "doc.badge.arrow.up",
                    accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg)
            else { return true }
            let s = sym.size
            sym.draw(
                in: CGRect(
                    x: (rect.width - s.width) / 2,
                    y: (rect.height - s.height) / 2,
                    width: s.width,
                    height: s.height))
            return true
        }

        // Frame is in the view's own coordinate space — center over the well.
        item.setDraggingFrame(
            CGRect(
                x: bounds.midX - canvasSize / 2,
                y: bounds.midY - canvasSize / 2,
                width: canvasSize,
                height: canvasSize),
            contents: ghost)

        beginDraggingSession(with: [item], event: event, source: self)
    }

    // MARK: - NSFilePromiseProviderDelegate

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "MockTab-\(fmt.string(from: Date())).json"
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task { @MainActor in
            guard let data = self.generateJSON?() else {
                completionHandler(nil)
                return
            }
            do {
                try data.write(to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

// MARK: - NSBezierPath → CGPath

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            default: break
            }
        }
        return path
    }
}
