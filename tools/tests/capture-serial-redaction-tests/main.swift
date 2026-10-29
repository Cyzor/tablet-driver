// Checks for the serial stand-ins applied to submitted captures.
//
// Compiles the real `CaptureSerialRedaction` rather than restating it. The
// frames follow the layout of actual submissions: a DTH-2700 desk with an
// ExpressKey Remote, and a Cintiq Pro 16. The serials are made up.
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
func redacted(_ bytes: [UInt8], _ productID: Int = 0) -> [UInt8] {
    CaptureSerialRedaction.redacted(bytes, productID: productID)
}

// MARK: - ExpressKey Remote

// Report 0x10, the receiver's pairing table: serial 0x001234 in slot 0, slot 4
// filled too, the rest empty.
var pairing = [UInt8](repeating: 0, count: 32)
pairing[0] = 0x10
pairing[2] = 0x01
pairing[4] = 0x34; pairing[5] = 0x12
pairing[28] = 0x99; pairing[29] = 0x88; pairing[30] = 0x77
let shownPairing = redacted(pairing, ekr)
check(Array(shownPairing[4...6]) != [0x34, 0x12, 0x00], "slot 0's serial is swapped")
check(Array(shownPairing[28...30]) != [0x99, 0x88, 0x77], "slot 4's serial is swapped")
check(Array(shownPairing[10...12]) == [0, 0, 0], "an empty slot stays empty")
check(Array(shownPairing[0...3]) == [0x10, 0x00, 0x01, 0x00], "bytes before the serial survive")
check(redacted(pairing, ekr) == shownPairing, "the same remote gets the same stand-in")

// Report 0x11: the sending remote's serial at bytes 3–5.
var button: [UInt8] = [0x11, 0x01, 0x00, 0x34, 0x12, 0x00, 0x00, 0x64, 0x00, 0x01]
let shownButton = redacted(button, ekr)
check(Array(shownButton[3...5]) == Array(shownPairing[4...6]),
      "the sender and its pairing slot share a stand-in")
check(Array(shownButton[6...]) == Array(button[6...]), "battery and buttons survive")
button[3] = 0x35
check(Array(redacted(button, ekr)[3...5]) != Array(shownButton[3...5]),
      "a different remote gets a different stand-in")

// Position-based swapping only applies where the layout is known.
check(redacted(pairing, 0x032B) == pairing, "the same report ID on a tablet is untouched")

// MARK: - Pen serials

let proFrame: [UInt8] = [0x10, 0x60, 0x6F, 0x4F, 0x00, 0x60, 0x5E, 0x00, 0x00, 0x00,
                         0x1E, 0x23, 0x00, 0x00, 0x00, 0x00, 0x3F,
                         0x78, 0x56, 0x34, 0x12, 0x42, 0x08, 0x10, 0x00, 0x42, 0x08]
check(redacted(proFrame) == proFrame, "nothing changes before a pen announces itself")

// A Cintiq Pro repeats the serial (here 0x12345678) LE at bytes 17–20.
CaptureSerialRedaction.noteToolEnter(serial: 0x1234_5678)
let shownPro = redacted(proFrame)
let standIn = CaptureSerialRedaction.standIn(forPenSerial: 0x1234_5678)
check(Array(shownPro[17...20]) == (0..<4).map { UInt8(truncatingIfNeeded: standIn >> ($0 * 8)) },
      "the serial's bytes carry the stand-in the decoded line prints")
check(Array(shownPro[0...16]) == Array(proFrame[0...16])
      && Array(shownPro[21...]) == Array(proFrame[21...]),
      "everything else survives")

// A 27QHD announcement packs the serial big-endian from bit 28 of byte 3.
// Only the announcement carries it, so a serial known beforehand waits for one.
let qhd = 0x032B
let packed: [UInt8] = [0x10, 0xC2, 0x80, 0x20, 0x76, 0x54, 0x32, 0x11, 0x60, 0x00]
CaptureSerialRedaction.noteToolEnter(serial: 0x0765_4321)
check(redacted(packed, qhd) == packed, "a packed serial isn't searched for at bit offsets")
CaptureSerialRedaction.noteToolEnter(serial: 0x0765_4321, in: packed, productID: qhd)
let shownPacked = redacted(packed, qhd)
check(shownPacked != packed, "a nibble-packed serial is swapped")
check(CaptureSerialRedaction.penSerialByteOffsets(productID: qhd, reportID: 0x10) == [3, 4, 5, 6, 7],
      "the summary withholds the packed serial's bytes")
check(Array(shownPacked[0...2]) == Array(packed[0...2]) && shownPacked[3] >> 4 == 0x2
      && shownPacked[7] & 0x0F == 0x1 && Array(shownPacked[8...]) == Array(packed[8...]),
      "the tool-code nibbles around it survive")
check(redacted([0x10, 0x80, 0, 0, 0, 0, 0, 0, 0, 0]) == [0x10, 0x80, 0, 0, 0, 0, 0, 0, 0, 0],
      "an unrelated pen report is untouched")

// Serial 0 means the protocol has none, and must not swap runs of zeros.
CaptureSerialRedaction.noteToolEnter(serial: 0)
check(redacted([0x02, 0, 0, 0, 0, 0]) == [0x02, 0, 0, 0, 0, 0], "a zero serial changes nothing")
check(CaptureSerialRedaction.standIn(forPenSerial: 0) == 0, "a missing serial prints as 0")
check(standIn != 0x1234_5678 && standIn == CaptureSerialRedaction.standIn(forPenSerial: 0x1234_5678),
      "a pen stand-in is stable and isn't the serial")

// MARK: - Short serials

// An Intuos Pro M (PTH-660) submission, its pen already in range. The app
// seeds every serial it has seen, short ones included; matched at any bit
// offset, those rewrote tilt, pressure, and hover, and kept the real serial
// from being swapped. The pen's serial (0x5A3C1E97) is made up.
let pth660 = 0x0357
for serial: UInt32 in [3, 0x24, 0x3F, 0xA4, 0x5A3C_1E97] {
    CaptureSerialRedaction.noteToolEnter(serial: serial)
}
let weak: [UInt8] = [0x10, 0x40, 0x39, 0x0E, 0x00, 0xAE, 0x2E, 0x00, 0x00, 0x00,
                     0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3F,
                     0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
let hover: [UInt8] = [0x10, 0x60, 0xAD, 0x26, 0x00, 0x2C, 0x2E, 0x00, 0x00, 0x00,
                      0xA4, 0x24, 0x00, 0x00, 0x00, 0x00, 0x3F,
                      0x97, 0x1E, 0x3C, 0x5A, 0x42, 0x08, 0x10, 0x00, 0x42, 0x08]
let contact: [UInt8] = [0x10, 0x61, 0xCE, 0x61, 0x00, 0x6C, 0x16, 0x00, 0x4D, 0x05,
                        0x01, 0x26, 0x00, 0x00, 0x00, 0x00, 0x0B,
                        0x97, 0x1E, 0x3C, 0x5A, 0x42, 0x08, 0x10, 0x00, 0x42, 0x08]
check(redacted(weak, pth660) == weak, "a frame without a serial is untouched")
let penStandIn = CaptureSerialRedaction.standIn(forPenSerial: 0x5A3C_1E97)
let penStandInBytes = (0..<4).map { UInt8(truncatingIfNeeded: penStandIn >> ($0 * 8)) }
for (frame, label) in [(hover, "hovering"), (contact, "in contact")] {
    let shown = redacted(frame, pth660)
    check(Array(shown[17...20]) == penStandInBytes, "the serial is swapped \(label)")
    check(Array(shown[0...16]) == Array(frame[0...16]) && Array(shown[21...]) == Array(frame[21...]),
          "position, pressure, tilt, and hover survive \(label)")
}
check(CaptureSerialRedaction.penSerialByteOffsets(productID: pth660, reportID: 0x10) == [17, 18, 19, 20],
      "the summary withholds the serial's bytes, though the first frame had none")

// A short serial a report announces is swapped where it sits, and nowhere else.
let otherTablet = 0x00B9
var short = hover
short[17...20] = [0x3F, 0x00, 0x00, 0x00]
CaptureSerialRedaction.noteToolEnter(serial: 0x3F, in: short, productID: otherTablet)
let shownShort = redacted(short, otherTablet)
check(shownShort[16] == 0x3F && Array(shownShort[0...15]) == Array(short[0...15]),
      "a hover distance equal to a short serial survives")
check(Array(shownShort[17...20]) != [0x3F, 0x00, 0x00, 0x00], "the short serial is swapped")

if fails == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("\(fails) of \(checks) checks failed\n".utf8))
exit(1)
