// Checks that ButtonBinding/TouchRingMode's machine-readable encodings
// round-trip independent of the display label, since PresetExporter/
// PresetImporter previously relied on `displayLabel` (a localized string)
// for import decoding — correct only when the app ran in English at both
// export and import time. See PresetExporter.swift / PresetImporter.swift.

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
    ButtonBinding(kind: .middleClickWithTip),
    .eraser,
    ButtonBinding(kind: .displayToggle),
    ButtonBinding(kind: .doubleClick),
    ButtonBinding(kind: .spacebar),
    ButtonBinding(kind: .ringCycle),
    ButtonBinding(kind: .ringSelectSlot, keyCode: 2),
    .scrollDrag,
    ButtonBinding(kind: .relativeModeToggle),
    ButtonBinding(kind: .keyCombo, keyCode: 6, modifierFlags: CGEventFlags.maskCommand.rawValue, keyLabel: "Z"),
]

for binding in sampleBindings {
    let encoded = binding.encoded
    check(!encoded.isEmpty, "encoded() produced an empty string for \(binding)")
    let decoded = ButtonBinding.decode(encoded)
    check(decoded == binding, "round-trip mismatch: \(binding) -> \(encoded) -> \(String(describing: decoded))")
}

// MARK: - The actual bug this guards against: a foreign-language label must
// not silently decode when a machine key is present (import prefers the key).

// Simulates PresetImporter.decodeDeviceSettings' penButton1Key branch.
func decodePenButtonKeyBranch(key: String?, label: String) -> ButtonBinding {
    if let key, !key.isEmpty {
        return ButtonBinding.decode(key) ?? .none
    }
    return ButtonBinding.fromDisplayLabel(label)
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

// MARK: - TouchRingMode: rawValue round-trip (the export/import contract for touchRingKey)

for mode in TouchRingMode.allCases {
    let decoded = TouchRingMode(rawValue: mode.rawValue)
    check(decoded == mode, "TouchRingMode rawValue round-trip failed for \(mode)")
}
check(TouchRingMode(rawValue: "Scrollen") == nil, "sanity check: a German label should not parse as a TouchRingMode rawValue")

if failures == 0 {
    print("All preset-locale checks passed.")
} else {
    print("\(failures) check(s) failed.")
    exit(1)
}
