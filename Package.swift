// swift-tools-version:5.9
//
// SwiftPM sidecar package for unit-testing the pure-logic parts of MockTab.
//
// This file does NOT replace the Xcode project — `MockTab.xcodeproj` remains
// the build of record for the app. The package exists so the decoder layer
// (which is pure Swift, no AppKit / SwiftUI / UI dependencies) can be tested
// without standing up an XCTest target inside the Xcode project.
//
// Run from the project root:
//     swift test
//
// To add another testable module, add a `.target` here listing the relevant
// `MockTab/...` source files, then write tests under `Tests/<Name>Tests/`.
import PackageDescription

let package = Package(
    name: "MockTabDecoders",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MockTabDecoders",
            path: "MockTab",
            exclude: [
                "App", "Assets.xcassets", "Driver/AppWatcher.swift",
                "Driver/CaptureEngine.swift", "Driver/CaptureModels.swift",
                "Driver/DeviceContext.swift", "Driver/DeviceRegistry.swift",
                "Driver/HIDCapture.swift", "Driver/HIDThread.swift",
                "Driver/InjectionSnapshot.swift", "Driver/InputInjector.swift",
                "Driver/OTDImporter.swift", "Driver/TabletManager.swift",
                "Driver/WacomDeviceRegistry.swift",
                "Driver/WacomFallbackDevice.swift",
                "Driver/WacomKnownDevice.swift", "Driver/WacomProbeDevice.swift",
                "Help", "Info.plist", "Localizable.xcstrings",
                "MockTab.entitlements", "MocktabAppIcon-v0.icon",
                "PrivacyInfo.xcprivacy", "Services", "Settings", "UI",
                "example-profile.json",
            ],
            sources: [
                "Driver/TabletPoint.swift",
                "Driver/TabletDevice.swift",
                "Driver/WacomToolSpec.swift",
                "Driver/ModifierMath.swift",
                "Driver/Decoders",
            ]
        ),
        .testTarget(
            name: "MockTabDecodersTests",
            dependencies: ["MockTabDecoders"],
            path: "Tests/MockTabDecodersTests"
        ),
    ]
)
