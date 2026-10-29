// Checks that ButtonBinding/TouchRingMode's machine-readable encodings
// round-trip independent of the display label, since ConfigurationExporter/
// ConfigurationImporter previously relied on `displayLabel` (a localized string)
// for import decoding — correct only when the app ran in English at both
// export and import time. See ConfigurationExporter.swift / ConfigurationImporter.swift.

import CoreGraphics
import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        failures += 1
    }
}

// MARK: - ButtonBinding: encoded/decode round-trip for every representative kind

let sampleBindings: [ButtonBinding] = [
    .none,
    .leftClick,
    .rightClick,
    .middleClick,
    .eraser,
    ButtonBinding(kind: .displayToggle),
    ButtonBinding(kind: .doubleClick),
    ButtonBinding(kind: .spacebar),
    ButtonBinding(kind: .ringCycle),
    ButtonBinding(kind: .ringSelectSlot, keyCode: 2),
    .scrollDrag,
    ButtonBinding(kind: .relativeModeToggle),
    ButtonBinding(kind: .spanDisplaysToggle),
    ButtonBinding(kind: .keyCombo, keyCode: 6, modifierFlags: CGEventFlags.maskCommand.rawValue, keyLabel: "Z"),
]

for binding in sampleBindings {
    let encoded = binding.encoded
    check(!encoded.isEmpty, "encoded() produced an empty string for \(binding)")
    let decoded = ButtonBinding.decode(encoded)
    check(decoded == binding, "round-trip mismatch: \(binding) -> \(encoded) -> \(String(describing: decoded))")
}

// MARK: - Retired Middle Click + Tip loads as Middle Click

let legacyMiddleWithTip = #"{"kind":"middleClickWithTip","keyCode":0,"modifierFlags":0,"keyLabel":""}"#
check(
    ButtonBinding.decode(legacyMiddleWithTip) == .middleClick,
    "a saved middleClickWithTip binding should load as .middleClick")
check(
    ButtonBinding.fromDisplayLabel("Middle Click + Tip") == .middleClick,
    "an exported \"Middle Click + Tip\" label should import as .middleClick")

// MARK: - The actual bug this guards against: a foreign-language label must
// not silently decode when a machine key is present (import prefers the key).

// The importer's choice for one action, as ConfigurationImporter calls it.
func decodePenButtonKeyBranch(key: String?, label: String) -> ButtonBinding {
    ButtonBinding.importedValue(key: key, label: label).flatMap(ButtonBinding.decode) ?? .none
}

let germanLabelForRightClick = "Rechtsklick"  // not decodable by fromDisplayLabel (English-only)
check(
    ButtonBinding.fromDisplayLabel(germanLabelForRightClick) == .none,
    "sanity check failed: fromDisplayLabel unexpectedly decoded a German label — the bug this test guards against may already be fixed differently"
)
let resolvedViaKey = decodePenButtonKeyBranch(key: ButtonBinding.rightClick.encoded, label: germanLabelForRightClick)
check(
    resolvedViaKey == .rightClick,
    "key-preferred decode failed: expected .rightClick from the key field despite a German label, got \(resolvedViaKey)"
)

// MARK: - An action this build can't read survives export and import

// Exporting used to write no machine value for it, and importing its raw
// text as a label made it None.
let futureAction = #"{"kind":"futureAction","keyCode":0,"modifierFlags":0,"keyLabel":""}"#
let garbled = #"{"kind":"leftClick"}"#  // missing required fields
for stored in [futureAction, garbled] {
    let key = ButtonBinding.exportedKey(stored: stored, effective: .rightClick)
    let imported = ButtonBinding.importedValue(key: key, label: "Right Click")
    // An unknown kind decodes unequal to a real None; a garbled one not at all.
    check(
        imported != nil && imported.flatMap(ButtonBinding.decode) != ButtonBinding.none,
        "an unreadable action should not import as None: \(stored)")
}
let futureKey = ButtonBinding.exportedKey(stored: futureAction, effective: .rightClick)
check(
    ButtonBinding.decode(futureKey)?.unrecognizedKindName == "futureAction",
    "an unknown action should export with its kind")
check(
    ButtonBinding.importedValue(key: futureKey, label: "Right Click")
        .flatMap(ButtonBinding.decode)?.unrecognizedKindName == "futureAction",
    "an unknown action should import with its kind")
check(
    ButtonBinding.exportedKey(stored: garbled, effective: .rightClick) == garbled
        && ButtonBinding.importedValue(key: garbled, label: nil) == garbled,
    "an action that doesn't decode should export and import verbatim")
check(
    ButtonBinding.importedValue(key: nil, label: futureAction) == futureAction,
    "an older export's raw action in the label's place should import verbatim")
check(
    ButtonBinding.decode(ButtonBinding.exportedKey(stored: "", effective: .rightClick)) == .rightClick,
    "nothing stored should export the action in effect")
check(
    ButtonBinding.importedValue(key: nil, label: nil) == nil
        && ButtonBinding.importedValue(key: "", label: "") == nil,
    "a file without the action should import nothing")
check(
    ButtonBinding.importedValue(key: ButtonBinding.none.encoded, label: "None")
        .flatMap(ButtonBinding.decode) == ButtonBinding.none,
    "a saved None should still import as None")

// MARK: - TouchRingMode: rawValue round-trip (the export/import contract for touchRingKey)

for mode in TouchRingMode.allCases {
    let decoded = TouchRingMode(rawValue: mode.rawValue)
    check(decoded == mode, "TouchRingMode rawValue round-trip failed for \(mode)")
}
check(TouchRingMode(rawValue: "Scrollen") == nil, "sanity check: a German label should not parse as a TouchRingMode rawValue")

if failures == 0 {
    print("All configuration-locale checks passed.")
} else {
    print("\(failures) check(s) failed.")
    exit(1)
}
