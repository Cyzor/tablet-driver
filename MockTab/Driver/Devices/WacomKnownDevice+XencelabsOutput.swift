// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog
import TabletKit

// Same category as WacomKnownDevice.swift's; `private` is file-scoped, and
// each sibling driver file declares its own the same way.
private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "driver")

// Xencelabs vendor output: OLED text, dial colors, display controls, and the
// paced/queued vendor-write path they share. Split out of
// WacomKnownDevice.swift; behavior unchanged, stored state stays there.

extension WacomKnownDevice {

    // MARK: - Xencelabs OLED / dial output

    /// Adopt per-slot custom dial colors (nil = factory palette) and re-send
    /// the active slot's color if anything changed. Deduped here because the
    /// settings pipeline re-fires this on every settings change.
    func setRingLEDColors(_ colors: [(r: UInt8, g: UInt8, b: UInt8)?]) {
        guard deviceSpec.parser == .xencelabs else { return }
        guard !dialSlotColors.elementsEqual(colors, by: { a, b in
            a?.r == b?.r && a?.g == b?.g && a?.b == b?.b
        }) else { return }
        dialSlotColors = colors
        setRingLED(index: pendingLEDIndex)
    }

    /// Show the active dial mode's name on the Quick Keys OLED mode line.
    func setRingModeLabel(_ label: String) {
        guard deviceSpec.parser == .xencelabs else { return }
        guard xencelabsSentText["mode"] != label else { return }
        xencelabsSentText["mode"] = label
        for payload in XencelabsOutputProtocol.textPayloads(
            field: .modeName, text: label, address: xencelabsDongleIdentity ?? [])
        {
            sendXencelabsOutput(payload, tag: "OLED mode label")
        }
    }

    /// Sync per-key labels (labels[0] = key 1) to the Quick Keys OLED.
    func setAuxKeyLabels(_ labels: [String]) {
        if deviceSpec.parser == .xencelabs {
            let joined = labels.joined(separator: "\u{1F}")
            guard xencelabsSentText["keys"] != joined else { return }
            xencelabsSentText["keys"] = joined
            for payload in XencelabsOutputProtocol.keyLabelPayloads(labels, address: xencelabsDongleIdentity ?? []) {
                sendXencelabsOutput(payload, tag: "OLED key labels")
            }
        } else if deviceSpec.hasKeyOLEDs {
            setIntuos4KeyOLEDLabels(labels)
        }
    }

    /// Render each label to a bitmap and push it to the Intuos4's per-key
    /// OLED, USB transport only (see `WacomOutputProtocol`'s header for
    /// provenance — kernel-sourced, not hardware-verified).
    ///
    /// Deduped per key against `intuos4SentKeyLabels`, since a full image
    /// sync is ~1KB of feature-report traffic per key versus a short text
    /// write for Xencelabs.
    private func setIntuos4KeyOLEDLabels(_ labels: [String]) {
        for (index, label) in labels.enumerated() where index < 8 {
            let previous = index < intuos4SentKeyLabels.count ? intuos4SentKeyLabels[index] : nil
            guard previous != label else { continue }
            while intuos4SentKeyLabels.count <= index {
                intuos4SentKeyLabels.append("")
            }
            intuos4SentKeyLabels[index] = label

            let bitmap = IntuosOLEDImageEncoder.renderTextLabel(label)
            guard let packed = IntuosOLEDImageEncoder.interleaveRows(bitmap) else { continue }

            sendIntuos4Feature(WacomOutputProtocol.imageStartPayload(), tag: "Intuos4 OLED key\(index) start")
            for chunk in WacomOutputProtocol.keyImagePayloadsUSB(image: packed, buttonID: index) {
                sendIntuos4Feature(chunk, tag: "Intuos4 OLED key\(index) chunk")
            }
            sendIntuos4Feature(WacomOutputProtocol.imageStopPayload(), tag: "Intuos4 OLED key\(index) stop")
        }
    }

    /// Send one Intuos4 OLED feature-report payload. Best-effort: a garbled
    /// write shows a garbled label on the key's own OLED and nothing else —
    /// there's no persistent device state at risk, so failures are logged
    /// rather than treated as fatal.
    private func sendIntuos4Feature(_ payload: [UInt8], tag: String) {
        var bytes = payload
        let reportID = CFIndex(payload[0])
        hidSetReport(device, reportID: reportID, bytes: &bytes, tag: tag, severity: .bestEffort, log: logger)
    }

    /// Panel brightness is exposed on Xencelabs pen displays via the vendor
    /// 0xB5 display-control frame family (see XencelabsOutputProtocol).
    var hasDisplayBrightnessControl: Bool {
        deviceSpec.parser == .xencelabs && deviceSpec.isPenDisplay
    }

    /// Set the Quick Keys OLED text orientation, in 90° steps (0 = upright,
    /// 1–3 = 90°/180°/270°). Same wire command already used to reassert
    /// upright orientation on relink (`resyncXencelabsOutputsAfterRelink`);
    /// this is an independent, settings-driven entry point pre-wired ahead
    /// of a UI control — no caller sets a value other than the sentinel yet.
    func setQuickKeysOrientation(steps: Int) {
        guard deviceSpec.parser == .xencelabs else { return }
        let clamped = ((steps % 4) + 4) % 4
        guard clamped != lastQuickKeysOrientation else { return }
        lastQuickKeysOrientation = clamped
        sendXencelabsOutput(
            XencelabsOutputProtocol.orientationPayload(
                rotationSteps: clamped, address: xencelabsDongleIdentity ?? []),
            tag: "quick keys orientation \(clamped)")
    }

    /// Set the Quick Keys' auto-sleep timer, in minutes (0 = never sleep).
    /// Hardware-confirmed 2026-07-26: a value written this way survives a
    /// puck power cycle and reads back correctly in the native panel.
    func setQuickKeysSleepMinutes(_ minutes: Int) {
        guard deviceSpec.parser == .xencelabs else { return }
        let clamped = min(max(minutes, 0), 255)
        guard clamped != lastQuickKeysSleepMinutes else { return }
        lastQuickKeysSleepMinutes = clamped
        sendXencelabsOutput(
            XencelabsOutputProtocol.sleepTimerPayload(
                minutes: UInt8(clamped), address: xencelabsDongleIdentity ?? []),
            tag: "quick keys sleep timer \(clamped)m")
    }

    /// Set the Quick Keys OLED's brightness level, 0 (off) through 3
    /// (bright). Distinct from `setDisplayBrightness`, which controls a pen
    /// display's panel backlight over a different frame family.
    func setQuickKeysOledBrightness(_ level: Int) {
        guard deviceSpec.parser == .xencelabs else { return }
        let clamped = min(max(level, 0), 3)
        guard clamped != lastQuickKeysOledBrightness else { return }
        lastQuickKeysOledBrightness = clamped
        sendXencelabsOutput(
            XencelabsOutputProtocol.oledBrightnessPayload(
                UInt8(clamped), address: xencelabsDongleIdentity ?? []),
            tag: "quick keys OLED brightness \(clamped)")
    }

    /// Set the pen display's panel backlight brightness (0–100).
    func setDisplayBrightness(_ percent: Int) {
        guard hasDisplayBrightnessControl else { return }
        let clamped = min(max(percent, 0), 100)
        guard clamped != lastDisplayBrightness else { return }
        lastDisplayBrightness = clamped
        sendXencelabsOutput(
            XencelabsOutputProtocol.displayBrightnessPayload(
                UInt8(clamped), address: xencelabsDongleIdentity ?? []),
            tag: "panel brightness \(clamped)")
    }

    /// Set the shared backlight LED behind the pen display's bezel buttons.
    /// Same wire command as the Quick Keys dial LED; brightness arrives
    /// premultiplied into the RGB (the LED has no brightness register).
    func setBezelLEDColor(r: UInt8, g: UInt8, b: UInt8) {
        guard hasDisplayBrightnessControl else { return }
        guard lastBezelLED?.r != r || lastBezelLED?.g != g || lastBezelLED?.b != b
        else { return }
        lastBezelLED = (r, g, b)
        sendXencelabsOutput(
            XencelabsOutputProtocol.dialColorPayload(
                r: r, g: g, b: b, address: xencelabsDongleIdentity ?? []),
            tag: "bezel LED")
    }

    /// Set the pen display's panel contrast (0–100). Same 0xB5 control family
    /// as brightness (see XencelabsOutputProtocol.DisplayControl).
    func setDisplayContrast(_ percent: Int) {
        guard hasDisplayBrightnessControl else { return }
        let clamped = min(max(percent, 0), 100)
        guard clamped != lastDisplayContrast else { return }
        lastDisplayContrast = clamped
        sendXencelabsOutput(
            XencelabsOutputProtocol.displayContrastPayload(
                UInt8(clamped), address: xencelabsDongleIdentity ?? []),
            tag: "panel contrast \(clamped)")
    }

    /// Set the pen display's gamma, passed as gamma × 10 (e.g. 22 = 2.2).
    func setDisplayGamma(_ gammaTimesTen: Int) {
        guard hasDisplayBrightnessControl else { return }
        let clamped = min(max(gammaTimesTen, 0), 255)
        guard clamped != lastDisplayGamma else { return }
        lastDisplayGamma = clamped
        sendXencelabsOutput(
            XencelabsOutputProtocol.displayGammaPayload(
                UInt8(clamped), address: xencelabsDongleIdentity ?? []),
            tag: "panel gamma \(clamped)")
    }

    /// Select one of the panel's built-in color-space presets (Adobe RGB,
    /// sRGB, REC 709, DCI-P3, REC 2020, Pantone, Custom), by row index (0 =
    /// Adobe RGB ... 6 = Custom, matching `DisplayMappingView.colorModeChoices`).
    ///
    /// Empirically confirmed 2026-07-12 by cycling MockTab's list against the
    /// vendor driver's own preset selector on the same panel: wire byte 0
    /// isn't a valid preset (it produced the original "too dark/warm" Adobe
    /// RGB bug), and every named preset is one byte higher than its row
    /// index — Adobe RGB=1, sRGB=2, REC 709=3, DCI-P3=4, REC 2020=5,
    /// Pantone=6, Custom presumed=7 (untested — one past anything we'd sent
    /// before this fix, consistent with never having matched Pantone).
    ///
    /// Followed by the apply-batch commit frame the vendor also sends after
    /// a preset switch — without it, a prior stray gamma/contrast write can
    /// linger on the panel instead of being reset to the new preset's own
    /// stored values (found 2026-07-12 comparing against the vendor driver).
    func setColorMode(_ index: Int) {
        guard hasDisplayBrightnessControl else { return }
        guard index != lastColorMode else { return }
        lastColorMode = index
        let address = xencelabsDongleIdentity ?? []
        sendXencelabsOutput(
            XencelabsOutputProtocol.colorModePayload(UInt8(index + 1), address: address),
            tag: "panel color mode \(index)")
        sendXencelabsOutput(
            XencelabsOutputProtocol.displayCommitPayload(address: address),
            tag: "panel color mode commit")
    }

    /// Send the tablet-mode relink handshake ([0x02, 0xB0, 0x04] with the
    /// puck's identity appended) to the dongle's vendor interface, padded to
    /// the declared output size. Used at first sight of the puck and again
    /// after its ~5 s wake window (see the relink block in `handleReport`).
    @discardableResult
    func sendXencelabsRelink(identity: [UInt8]) -> IOReturn {
        let target = secondaryDevice ?? device
        var relink: [UInt8] = [0x02, 0xB0, 0x04, 0, 0, 0, 0, 0, 0, 0] + identity
        let declared = hidIntProperty(target, kIOHIDMaxOutputReportSizeKey)
        if declared > relink.count {
            relink += [UInt8](repeating: 0, count: declared - relink.count)
        }
        paceXencelabsWrite()
        return hidSetReport(
            target, type: kIOHIDReportTypeOutput, reportID: CFIndex(relink[0]),
            bytes: &relink, tag: "\(deviceSpec.name) dongle relink", log: logger)
    }

    /// Resend the ring LED and OLED labels once a dongle relink is confirmed
    /// live. `setRingLED` has no dedup, so it's safe to call as-is; the OLED
    /// label setters dedup against `xencelabsSentText`, so that cache is
    /// cleared first to force the resend of whatever was last requested.
    func resyncXencelabsOutputsAfterRelink() {
        // What captures showed as a "reset labels" write here (0xB1 0x01)
        // is really the screen orientation command set to upright —
        // `setRingLED` below reasserts it, so no separate write is needed.
        // The three extra opcodes in every native resync capture turned
        // out to be status GET polls (0xB4 0x08 sleep time, 0xB4 0x10
        // battery, 0xB1 0x0A OLED brightness; byte 3 = 0x01 set / 0x00
        // get) — decoded 2026-07-10 from the vendor agent's disassembly.
        // Replaying them is kept: they're cheap, present in every native
        // capture, and may double as wake pokes during the reconnect
        // window.
        if let identity = xencelabsDongleIdentity {
            sendXencelabsOutput([0x02, 0xB4, 0x08, 0, 0, 0, 0, 0, 0, 0] + identity, tag: "sleep-time poll")
            sendXencelabsOutput([0x02, 0xB4, 0x10, 0, 0, 0, 0, 0, 0, 0] + identity, tag: "battery poll")
            sendXencelabsOutput([0x02, 0xB1, 0x0A, 0, 0, 0, 0, 0, 0, 0] + identity, tag: "OLED brightness poll")
        }
        let ledIndex = pendingLEDIndex
        let modeLabel = xencelabsSentText["mode"]
        let keysJoined = xencelabsSentText["keys"]
        xencelabsSentText.removeAll()
        setRingLED(index: ledIndex)
        if let modeLabel { setRingModeLabel(modeLabel) }
        if let keysJoined { setAuxKeyLabels(keysJoined.components(separatedBy: "\u{1F}")) }
    }

    /// Starts (or restarts) the repeating battery-level poll once a dongle
    /// relink is confirmed live. 60 s cadence: battery drains slowly enough
    /// that this is purely a "keep the status bar honest" refresh, not a
    /// latency-sensitive read. Runs on a background queue rather than main
    /// since `sendXencelabsOutput` can block for a few ms on write pacing.
    func startXencelabsBatteryPolling() {
        xencelabsBatteryPollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "xencelabs.battery.poll"))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, let identity = self.xencelabsDongleIdentity else { return }
            self.sendXencelabsOutput([0x02, 0xB4, 0x10, 0, 0, 0, 0, 0, 0, 0] + identity, tag: "battery poll")
        }
        timer.resume()
        xencelabsBatteryPollTimer = timer
    }

    /// Space vendor writes at least 3 ms apart. The vendor stack sleeps
    /// after every frame it sends (3 ms in its driver's color path, 1.3 ms
    /// between OLED label chunks, 10 ms between the color/sensitivity/label
    /// blocks on an app change — confirmed 2026-07-10 by disassembling
    /// XencelabsAgent/XencelabsDriver). The firmware silently drops output
    /// reports that arrive while it is busy repainting, and the transport
    /// still returns success, so back-to-back writes "succeed" without ever
    /// reaching the display.
    private func paceXencelabsWrite() {
        let gap: UInt64 = 3_000_000  // 3 ms in nanoseconds
        let now = DispatchTime.now().uptimeNanoseconds
        if lastXencelabsWriteUptime != 0 {
            let elapsed = now &- lastXencelabsWriteUptime
            if elapsed < gap {
                usleep(UInt32((gap - elapsed) / 1_000))
            }
        }
        lastXencelabsWriteUptime = DispatchTime.now().uptimeNanoseconds
    }

    /// Replay writes that arrived before the vendor tunnel did, in order.
    /// Called once, from `registerDevice`, the moment `secondaryDevice` is
    /// set — every one of these would otherwise have been lost.
    func flushPendingVendorWrites() {
        guard !pendingVendorWrites.isEmpty else { return }
        let queued = pendingVendorWrites
        pendingVendorWrites.removeAll()
        pendingVendorWritesDropped = false
        logger.info("\(self.deviceSpec.name, privacy: .public): vendor tunnel registered — replaying \(queued.count, privacy: .public) queued write(s)")
        for write in queued {
            sendXencelabsOutput(write.bytes, tag: write.tag)
        }
    }

    /// Send a Xencelabs vendor output report, zero-padded to the device's
    /// declared MaxOutputReportSize (short writes return success but are
    /// silently ignored by this firmware — same rule as the init path).
    func sendXencelabsOutput(_ bytes: [UInt8], tag: String) {
        // `device` is fixed at construction to whichever interface arrived
        // first — for Quick Keys that's usually the decorative digitizer
        // interface, not the vendor tunnel (0xFF0A). `secondaryDevice` is
        // updated in registerDevice() to the vendor interface once it's seen
        // (see acceptsReports(from:)), so prefer it here; this was still
        // pointed at the wrong interface even after that fix landed, which is
        // why OLED/dial-LED writes kept failing with 0xe0005000. Confirmed
        // 2026-07-05.
        // No tunnel yet, and the interface we were constructed with is not
        // one: this write cannot succeed. Hold it for the flush in
        // `registerDevice` rather than burning it on the wrong interface.
        if deviceSpec.parser == .xencelabs, secondaryDevice == nil,
            !acceptsReports(from: device)
        {
            if pendingVendorWrites.count < Self.maxPendingVendorWrites {
                pendingVendorWrites.append((bytes, tag))
            } else if !pendingVendorWritesDropped {
                pendingVendorWritesDropped = true
                logger.info("\(self.deviceSpec.name, privacy: .public): vendor tunnel still absent after \(Self.maxPendingVendorWrites, privacy: .public) queued writes — dropping the rest")
            }
            return
        }

        let target = (deviceSpec.parser == .xencelabs ? secondaryDevice : nil) ?? device
        let declared = hidIntProperty(target, kIOHIDMaxOutputReportSizeKey)
        var padded = bytes
        if declared > padded.count {
            padded += [UInt8](repeating: 0, count: declared - padded.count)
        }
        paceXencelabsWrite()
        hidSetReport(target, type: kIOHIDReportTypeOutput,
                     reportID: CFIndex(padded[0]), bytes: &padded,
                     tag: "\(deviceSpec.name) \(tag)", severity: .bestEffort, log: logger)
    }
}
