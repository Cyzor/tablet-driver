// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TabletKit

// MARK: - OTD JSON Structures

/// Root structure of an OpenTabletDriver device configuration file.
/// Maps directly to OTD's JSON format for device definitions.
struct OTDDeviceConfig: Codable {
    let name: String
    let vendorID: Int
    let productID: Int
    let width: Int
    let height: Int
    let maxPressure: Int
    let buttons: Int?
    let resolution: Int?

    // OTD v0.6+ format with nested objects
    let specifications: OTDSpecifications?
    let digitizerIdentifiers: [OTDDigitizerIdentifier]?
    let auxiliaryIdentifiers: [OTDAuxiliaryIdentifier]?
    let attributes: OTDAttributes?

    // Legacy format fields
    let inputReportLength: Int?
    let reportParser: String?
    let featureInitializationReport: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case vendorID = "VendorID"
        case productID = "ProductID"
        case width = "Width"
        case height = "Height"
        case maxPressure = "MaxPressure"
        case buttons = "Buttons"
        case resolution = "Resolution"
        case specifications = "Specifications"
        case digitizerIdentifiers = "DigitizerIdentifiers"
        case auxiliaryIdentifiers = "AuxiliaryDeviceIdentifiers"
        case attributes = "Attributes"
        case inputReportLength = "InputReportLength"
        case reportParser = "ReportParser"
        case featureInitializationReport = "FeatureInitializationReport"
    }
}

/// OTD Specifications section (v0.6+)
struct OTDSpecifications: Codable {
    let digitizer: OTDDigitizerSpec?
    let pen: OTDPenSpec?
    let auxiliaryButtons: OTDButtonsSpec?
    let touchRing: OTDWheelSpec?
    let wheels: [OTDWheelSpec]?
}

struct OTDDigitizerSpec: Codable {
    let width: Double?
    let height: Double?
    let maxX: Int?
    let maxY: Int?
}

struct OTDPenSpec: Codable {
    let maxPressure: Int?
    let buttonCount: Int?
    let hasEraser: Bool?
}

struct OTDButtonsSpec: Codable {
    let buttonCount: Int?
}

struct OTDWheelSpec: Codable {
    let absoluteWheelMax: Int?
    let buttonCount: Int?
}

/// Device identifier entry from DigitizerIdentifiers array
struct OTDDigitizerIdentifier: Codable {
    let vendorID: Int
    let productID: Int
    let inputReportLength: Int?
    let reportParser: String?
    let featureInitReport: String?

    enum CodingKeys: String, CodingKey {
        case vendorID = "VendorID"
        case productID = "ProductID"
        case inputReportLength = "InputReportLength"
        case reportParser = "ReportParser"
        case featureInitReport = "FeatureInitReport"
    }
}

/// Auxiliary device identifier (for pad/buttons)
struct OTDAuxiliaryIdentifier: Codable {
    let vendorID: Int
    let productID: Int
    let inputReportLength: Int?
    let reportParser: String?
    let featureInitReport: String?

    enum CodingKeys: String, CodingKey {
        case vendorID = "VendorID"
        case productID = "ProductID"
        case inputReportLength = "InputReportLength"
        case reportParser = "ReportParser"
        case featureInitReport = "FeatureInitReport"
    }
}

/// OTD Attributes (configuration metadata)
struct OTDAttributes: Codable {
    let featureInitDelayMs: String?
    let wacomTabletUID: String?

    enum CodingKeys: String, CodingKey {
        case featureInitDelayMs = "FeatureInitDelayMs"
        case wacomTabletUID = "WacomTabletUID"
    }
}

// MARK: - OTD Tool Structures

/// Tool definition from OTD's Tools array
struct OTDTool: Codable {
    let toolType: String
    let serial: Int
    let buttonCount: Int

    enum CodingKeys: String, CodingKey {
        case toolType = "ToolType"
        case serial = "Serial"
        case buttonCount = "ButtonCount"
    }
}

// MARK: - Report Parser Mapping

/// Maps OTD ReportParser class names to MockTab parser families
enum OTDReportParser: String {
    // Legacy / old-format names
    case wacomDriverlessTablet = "WacomDriverlessTablet"
    case wacomDriverless = "WacomDriverless"
    case graphire = "Graphire"
    case intuosV1 = "IntuosV1"
    case intuos4V2 = "Intuos4V2"
    case wacomV1 = "WacomV1"
    case intuosV2 = "IntuosV2"
    case wacomV2 = "WacomV2"
    case bamboo = "Bamboo"
    case bambooV2 = "BambooV2"

    // Current OTD class-name suffixes
    case intuosReportParser = "IntuosReportParser"
    case intuosV1ReportParser = "IntuosV1ReportParser"
    case wacomDriverIntuosReportParser = "WacomDriverIntuosReportParser"
    case wacomDriverIntuosV1ReportParser = "WacomDriverIntuosV1ReportParser"
    case intuos3ReportParser = "Intuos3ReportParser"
    case wacomDriverIntuos3ReportParser = "WacomDriverIntuos3ReportParser"
    case intuos3ExtraAuxReportParser = "Intuos3ExtraAuxReportParser"
    case cintiqV1ReportParser = "CintiqV1ReportParser"
    case intuosV2ReportParser = "IntuosV2ReportParser"
    case wacomDriverIntuosV2ReportParser = "WacomDriverIntuosV2ReportParser"
    case intuosV3ReportParser = "IntuosV3ReportParser"
    case bambooReportParser = "BambooReportParser"
    case bambooPadReportParser = "BambooPadReportParser"

    /// Map to MockTab ReportParser enum
    func toReportParser() -> ReportParser? {
        switch self {
        case .wacomDriverlessTablet, .wacomDriverless, .graphire:
            return .graphire
        case .intuosV1, .intuos4V2, .wacomV1, .intuosReportParser,
            .intuosV1ReportParser, .wacomDriverIntuosReportParser,
            .wacomDriverIntuosV1ReportParser, .cintiqV1ReportParser:
            return .intuosV1
        case .intuosV2, .wacomV2, .intuosV2ReportParser,
            .wacomDriverIntuosV2ReportParser:
            return .intuosV2
        case .intuosV3ReportParser:
            return .intuosV3
        case .bamboo, .bambooV2, .bambooReportParser, .bambooPadReportParser:
            return .bamboo
        case .intuos3ReportParser, .wacomDriverIntuos3ReportParser,
            .intuos3ExtraAuxReportParser:
            return .intuos3
        }
    }

    /// Parse a ReportParser string from OTD
    static func parse(_ string: String?) -> OTDReportParser? {
        guard let string = string else { return nil }
        let suffix = string.split(separator: ".").last.map(String.init) ?? string
        return OTDReportParser(rawValue: suffix)
    }
}

// MARK: - Import Result

/// Result of importing a single OTD configuration
struct OTDImportResult {
    let deviceName: String
    let productID: Int
    let vendorID: Int
    let spec: WacomDeviceSpec?
    let tools: [OTDTool]
    let warnings: [String]
    let errors: [String]

    var isSuccess: Bool { spec != nil && errors.isEmpty }
}

// MARK: - OTD Importer

/// Imports OpenTabletDriver device configurations into MockTab's registry.
enum OTDImporter {

    /// Wacom vendor ID
    static let wacomVendorID = 0x056A

    /// Import a single OTD JSON configuration file.
    /// - Parameter url: URL to the .json file
    /// - Returns: Import result with device spec and warnings
    static func importFile(at url: URL) -> OTDImportResult {
        do {
            let data = try Data(contentsOf: url)
            return try importData(data, sourceURL: url)
        } catch {
            return OTDImportResult(
                deviceName: url.deletingPathExtension().lastPathComponent,
                productID: 0,
                vendorID: 0,
                spec: nil,
                tools: [],
                warnings: [],
                errors: ["Failed to read file: \(error.localizedDescription)"]
            )
        }
    }

    /// Import OTD configuration from JSON data.
    static func importData(_ data: Data, sourceURL: URL? = nil) throws -> OTDImportResult {
        let decoder = JSONDecoder()
        let config = try decoder.decode(OTDDeviceConfig.self, from: data)
        return try importConfig(config, sourceURL: sourceURL)
    }

    /// Import a decoded OTD configuration.
    static func importConfig(_ config: OTDDeviceConfig, sourceURL: URL? = nil) throws
        -> OTDImportResult
    {
        var warnings: [String] = []
        let errors: [String] = []

        // Validate vendor
        guard config.vendorID == wacomVendorID else {
            return OTDImportResult(
                deviceName: config.name,
                productID: config.productID,
                vendorID: config.vendorID,
                spec: nil,
                tools: [],
                warnings: [],
                errors: [
                    "Unsupported vendor ID: 0x\(String(config.vendorID, radix: 16)). Only Wacom (0x056A) is supported."
                ]
            )
        }

        // Get dimensions from specifications or legacy fields
        let (maxX, maxY, maxPressure) = extractDimensions(from: config)
        if maxX == 0 || maxY == 0 {
            warnings.append("Missing or zero dimensions - verify against hardware")
        }

        // Get button count
        let buttonCount =
            config.specifications?.auxiliaryButtons?.buttonCount
            ?? config.buttons
            ?? 0

        // Get touch ring info
        let hasTouchRing =
            config.specifications?.touchRing != nil
            || (config.specifications?.wheels?.isEmpty == false)

        // Determine parser family
        let parser = determineParser(from: config)
        guard let parser else {
            return OTDImportResult(
                deviceName: config.name,
                productID: config.productID,
                vendorID: config.vendorID,
                spec: nil,
                tools: [],
                warnings: warnings,
                errors: ["Cannot determine report parser for this device"]
            )
        }

        // Parse feature init reports
        let (featureInitBytes, _) = extractFeatureInit(from: config)

        // Build init steps from extracted bytes (OTD only supports single-stage init)
        var initSteps: [InitStep] = []
        if let bytes = featureInitBytes {
            initSteps = [.featureReport(bytes)]
        }

        // Determine if USB seizure is needed
        let seizeUSB = determineSeizeUSB(from: config)

        // Check if eraser is supported
        let hasEraser = config.specifications?.pen?.hasEraser ?? true

        // Create the device spec
        let spec = WacomDeviceSpec(
            productID: config.productID,
            name: config.name,
            parser: parser,
            maxX: maxX,
            maxY: maxY,
            maxPressure: maxPressure,
            buttonCount: buttonCount,
            hasTouchRing: hasTouchRing,
            hasDualRings: false,
            hasTouchStrips: false,
            hasEraser: hasEraser,
            seizeUSB: seizeUSB,
            initSteps: initSteps
        )

        // Extract tools if present (OTD v0.6+)
        // OTD doesn't expose tools in specifications, they're in a separate area
        // For now, we'll infer tools from the device family
        let tools: [OTDTool] = []

        return OTDImportResult(
            deviceName: config.name,
            productID: config.productID,
            vendorID: config.vendorID,
            spec: spec,
            tools: tools,
            warnings: warnings,
            errors: errors
        )
    }

    // MARK: - Helper Methods

    private static func extractDimensions(from config: OTDDeviceConfig) -> (
        x: Int, y: Int, pressure: Int
    ) {
        // Try new specifications format first
        if let specs = config.specifications {
            if let dig = specs.digitizer {
                let maxX = dig.maxX ?? Int(dig.width ?? 0) * 100
                let maxY = dig.maxY ?? Int(dig.height ?? 0) * 100
                let maxP = specs.pen?.maxPressure ?? config.maxPressure
                return (maxX, maxY, maxP)
            }
        }

        // Fall back to legacy fields
        return (config.width, config.height, config.maxPressure)
    }

    private static func determineParser(from config: OTDDeviceConfig) -> ReportParser? {
        // Try digitizer identifiers first
        if let identifiers = config.digitizerIdentifiers {
            for ident in identifiers {
                if let parser = OTDReportParser.parse(ident.reportParser)?.toReportParser() {
                    return parser
                }
                // Heuristic from report length
                if let len = ident.inputReportLength {
                    if len > 64 {
                        return .intuosV2
                    } else if len > 0 {
                        return .intuosV1
                    }
                }
            }
        }

        // Try legacy report parser field
        if let parser = OTDReportParser.parse(config.reportParser)?.toReportParser() {
            return parser
        }

        // Try legacy input report length
        if let len = config.inputReportLength {
            if len > 64 {
                return .intuosV2
            } else if len > 0 {
                return .intuosV1
            }
        }

        return nil
    }

    private static func extractFeatureInit(from config: OTDDeviceConfig) -> (
        [UInt8]?, Double
    ) {
        var featureInit: [UInt8]?
        var initDelay: Double = 0.15

        // Try digitizer identifiers for feature init
        if let identifiers = config.digitizerIdentifiers, let first = identifiers.first {
            if let report = first.featureInitReport {
                featureInit = decodeBase64FeatureInit(report)
            }
        }

        // Try legacy field
        if featureInit == nil, let report = config.featureInitializationReport {
            featureInit = decodeBase64FeatureInit(report)
        }

        // Get init delay from attributes
        if let delayMs = config.attributes?.featureInitDelayMs,
            let ms = Double(delayMs)
        {
            initDelay = ms / 1000.0
        }

        return (featureInit, initDelay)
    }

    private static func decodeBase64FeatureInit(_ encoded: String) -> [UInt8]? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return Array(data)
    }

    private static func determineSeizeUSB(from config: OTDDeviceConfig) -> Bool {
        // OTD signals seize via Interface == 0 in attributes
        // For now, we don't have this info in the new format
        // Default to false - most devices don't need seizure on macOS
        return false
    }

    // MARK: - Batch Import

    /// Import all OTD configurations from a directory.
    /// - Parameters:
    ///   - directory: URL to directory containing .json files
    ///   - skipExisting: If true, skip PIDs already in WacomDeviceRegistry
    /// - Returns: Tuple of (successful specs, warnings, errors)
    static func importDirectory(
        at directory: URL,
        skipExisting: Bool = true
    ) -> (specs: [WacomDeviceSpec], warnings: [String], errors: [String]) {

        var specs: [WacomDeviceSpec] = []
        var allWarnings: [String] = []
        var allErrors: [String] = []

        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return ([], [], ["Cannot enumerate directory: \(directory.path)"])
        }

        var existingPIDs = Set(WacomDeviceRegistry.knownDevices.map { $0.productID })

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "json" else { continue }

            let result = importFile(at: fileURL)

            if let spec = result.spec {
                // Skip if already exists and skipExisting is true
                if skipExisting && existingPIDs.contains(spec.productID) {
                    allWarnings.append(
                        "Skipped existing PID: 0x\(String(spec.productID, radix: 16)) (\(spec.name))"
                    )
                    continue
                }

                specs.append(spec)
                existingPIDs.insert(spec.productID)  // Prevent duplicates within batch

                for warning in result.warnings {
                    allWarnings.append("\(spec.name): \(warning)")
                }
            }

            for error in result.errors {
                allErrors.append("\(fileURL.lastPathComponent): \(error)")
            }
        }

        return (specs, allWarnings, allErrors)
    }

    /// Export specs to a format suitable for adding to WacomDeviceRegistry.
    static func generateSwiftCode(for specs: [WacomDeviceSpec]) -> String {
        var lines: [String] = []

        lines.append("// OTD-imported device specifications")
        lines.append("// Add these to WacomDeviceRegistry.knownDevices")
        lines.append("")

        for spec in specs.sorted(by: { $0.productID < $1.productID }) {
            lines.append("        .init(")
            lines.append("            productID: 0x\(String(format: "%04X", spec.productID)),")
            lines.append("            name: \"\(spec.name)\",")
            lines.append("            parser: .\(spec.parser.rawValue),")
            lines.append("            maxX: \(spec.maxX),")
            lines.append("            maxY: \(spec.maxY),")
            lines.append("            maxPressure: \(spec.maxPressure),")
            lines.append("            buttonCount: \(spec.buttonCount),")
            lines.append("            hasTouchRing: \(spec.hasTouchRing),")
            lines.append("            hasEraser: \(spec.hasEraser),")
            lines.append("            seizeUSB: \(spec.seizeUSB)")
            if !spec.initSteps.isEmpty {
                let stepsStr = spec.initSteps.map { step -> String in
                    switch step {
                    case .featureReport(let b):
                        let hex = b.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
                        return ".featureReport([\(hex)])"
                    case .outputReport(let b):
                        let hex = b.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
                        return ".outputReport([\(hex)])"
                    case .delay(let s):
                        return ".delay(\(s))"
                    case .stringDescriptor(let i):
                        return ".stringDescriptor(\(i))"
                    }
                }.joined(separator: ", ")
                lines.append("            initSteps: [\(stepsStr)]")
            }
            lines.append("        ),")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Tool Importer

/// Imports tool specifications from OTD conventions.
enum OTDToolImporter {

    /// Known OTD tool type strings to tool code mappings.
    /// These are inferred from OTD's tool detection logic.
    static let toolTypeMappings: [(otdType: String, toolCode: UInt16, name: String)] = [
        ("Pen", 0x0802, "Grip Pen"),
        ("Eraser", 0x080A, "Grip Pen (Eraser)"),
        ("Mouse", 0x0806, "Intuos Mouse"),
        ("Cursor", 0x0076, "Lens Cursor"),
        ("Airbrush", 0x0804, "Airbrush"),
        ("Art Pen", 0x07A0, "Art Pen"),
        ("Inking Pen", 0x0812, "Inking Pen"),
    ]

    /// Create a WacomToolSpec from an OTD tool definition.
    static func importTool(type: String, buttonCount: Int) -> WacomToolSpec? {
        // Find matching mapping
        guard let mapping = toolTypeMappings.first(where: { $0.otdType == type }) else {
            return nil
        }

        let hasTilt = ["Pen", "Eraser", "Art Pen", "Inking Pen", "Airbrush"].contains(type)
        let hasRotation = type == "Art Pen"
        let hasWheel = type == "Airbrush" || type == "Mouse"
        let isEraser = type == "Eraser"

        return WacomToolSpec(
            toolCode: mapping.toolCode,
            name: isEraser ? "\(mapping.name) (Eraser)" : mapping.name,
            toolType: mapToolType(type),
            buttonCount: buttonCount,
            maxPressure: nil,  // Device-dependent
            hasTilt: hasTilt,
            hasRotation: hasRotation,
            hasWheel: hasWheel,
            hasEraserVariant: !isEraser && type != "Mouse" && type != "Cursor",
            eraserToolCode: isEraser ? nil : (mapping.toolCode | 0x0008),
            supportedFamilies: []  // Universal
        )
    }

    private static func mapToolType(_ otdType: String) -> WacomToolType {
        switch otdType {
        case "Pen": return .stylus
        case "Eraser": return .eraser
        case "Mouse", "Cursor": return .mouse
        case "Touch": return .touch
        case "Airbrush": return .airbrush
        case "Art Pen": return .artPen
        case "Inking Pen": return .inkingPen
        default: return .stylus
        }
    }
}
