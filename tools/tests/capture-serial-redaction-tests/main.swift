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
let packed: [UInt8] = [0x10, 0xC2, 0x80, 0x20, 0x76, 0x54, 0x32, 0x11, 0x60, 0x00]
CaptureSerialRedaction.noteToolEnter(serial: 0x0765_4321)
let shownPacked = redacted(packed)
check(shownPacked != packed, "a nibble-packed serial is swapped")
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

if fails == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("\(fails) of \(checks) checks failed\n".utf8))
exit(1)
