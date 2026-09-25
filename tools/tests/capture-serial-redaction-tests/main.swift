// Checks for the serial redaction applied to submitted captures.
//
// Compiles the real `CaptureSerialRedaction` rather than restating it. The
// frames below are the ones an actual submission carried — a DTH-2700 desk
// whose ExpressKey Remote reported serial 23547 in plain bytes.
import Foundation

var fails = 0, checks = 0
func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        fails += 1
        FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8))
    }
}

let ekr = 0x0331

/// Applies the mask the exporter applies, so the checks read the result
/// rather than the offset list.
func masked(_ bytes: [UInt8], productID: Int, reportID: UInt8) -> String {
    let serial = Set(CaptureSerialRedaction.serialByteOffsets(
        productID: productID, reportID: reportID))
    return bytes.enumerated()
        .map { serial.contains($0.offset) ? "--" : String(format: "%02X", $0.element) }
        .joined()
}

// MARK: - The submitted frame

// Report 0x10, verbatim from `DTH-2700-0x0331_20260917_155547.json`: one
// remote paired in slot 0, serial 0x005BFB — 23547 — at bytes 4...6.
var pairing = [UInt8](repeating: 0, count: 32)
pairing[0] = 0x10
pairing[2] = 0x01
pairing[4] = 0xFB
pairing[5] = 0x5B

let maskedPairing = masked(pairing, productID: ekr, reportID: 0x10)
check(!maskedPairing.contains("FB5B"), "the paired serial does not survive masking")
check(maskedPairing.hasPrefix("100001"), "bytes before the serial are untouched")

// Occupancy must still be legible: that a slot was filled is the whole
// reason the pairing table is worth capturing.
let slotOffsets = CaptureSerialRedaction.serialByteOffsets(productID: ekr, reportID: 0x10)
check(!slotOffsets.contains(2), "the slot's own flag byte stays readable")
check(slotOffsets.contains(4) && slotOffsets.contains(5) && slotOffsets.contains(6),
      "slot 0's serial is masked")
check(slotOffsets.contains(28) && slotOffsets.contains(30),
      "slot 4's serial is masked, so later slots are not missed")
check(slotOffsets.count == 15, "five slots at three bytes each")

// MARK: - Report 0x11

// The sending remote's own serial sits at 3...5 on every button frame.
let button: [UInt8] = [
    0x11, 0x01, 0x00, 0x43, 0xB2, 0x01, 0x00, 0x64,
    0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
]
let maskedButton = masked(button, productID: ekr, reportID: 0x11)
check(!maskedButton.contains("43B201"), "the sending remote's serial is masked")
check(maskedButton.hasPrefix("110100"), "the report ID and status byte survive")
// Buttons and battery are what the frame is captured for.
check(maskedButton.hasSuffix("00640001008000000000"), "battery and buttons survive")

// MARK: - Scope

// Nothing else should lose bytes. Masking by position is only safe where the
// layout is known, so it must not reach a device this was never derived for.
check(CaptureSerialRedaction.serialByteOffsets(productID: ekr, reportID: 0x02).isEmpty,
      "an unrelated report ID is untouched")
check(CaptureSerialRedaction.serialByteOffsets(productID: 0x032B, reportID: 0x10).isEmpty,
      "the same report ID on the tablet is untouched")
check(CaptureSerialRedaction.serialByteOffsets(productID: 0x032B, reportID: 0x11).isEmpty,
      "a pen report is untouched — 0x11 means something else there")

if fails == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("\(fails) of \(checks) checks failed\n".utf8))
exit(1)
