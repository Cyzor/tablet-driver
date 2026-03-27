import Foundation
import IOKit.hid

/// Data-driven tablet driver backed by a `WacomDecoder` selected at init time.
///
/// Replaces per-device Swift classes for any product in `WacomDeviceRegistry`
/// whose parser family has a live decoder (IntuosV1, IntuosV2).
///
/// **Phase 3 routing** (in `TabletManager.deviceConnected`):
///   - Devices with an explicit legacy class (PTH-851/860/660, PTZ-631W,
///     DTK-2400) still use those classes until Phase 4 retirement.
///   - Unrecognised PIDs, stub families (Graphire, Bamboo), and the ACK-40401
///     dongle (zero-spec) fall through to `WacomGenericDevice`.
///   - All other recognised Wacom PIDs with a live decoder route here.
final class WacomUniversalDevice: TabletDevice {

    let spec: DigitizerSpec

    private let device: IOHIDDevice
    private let deviceSpec: WacomDeviceSpec
    /// True when this interface must be seized (kIOHIDOptionsTypeSeizeDevice).
    /// Only set by TabletManager when the interface is the standard HID-mouse
    /// interface (usagePage=0x01) AND the device spec requires seizure.
    private let seize: Bool
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private let onToolEnter: ((ToolIdentity) -> Void)?

    private var decoder: any WacomDecoder
    private var state = DecoderState()
    private var reportBuffer: [UInt8]

    init(
        device: IOHIDDevice,
        deviceSpec: WacomDeviceSpec,
        seize: Bool = false,
        onTablet: @escaping (TabletPoint) -> Void,
        onAux: ((AuxButtons) -> Void)? = nil,
        onToolEnter: ((ToolIdentity) -> Void)? = nil
    ) {
        self.device      = device
        self.deviceSpec  = deviceSpec
        self.seize       = seize
        self.onTablet    = onTablet
        self.onAux       = onAux
        self.onToolEnter = onToolEnter

        self.spec = DigitizerSpec(
            maxX: deviceSpec.maxX,
            maxY: deviceSpec.maxY,
            maxPressure: deviceSpec.maxPressure)

        switch deviceSpec.parser {
        case .intuosV2:
            self.decoder = IntuosV2Decoder()
        case .intuosV1, .graphire, .bamboo:
            // graphire/bamboo should not reach here — caller checks hasLiveDecoder.
            self.decoder = IntuosV1Decoder()
        }

        // Use at least 192 bytes so both IntuosV1 (10-byte pen, 64-byte BLE)
        // and IntuosV2 (192-byte) reports always fit.
        let maxSize = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
        reportBuffer = [UInt8](repeating: 0, count: Swift.max(maxSize, 192))
    }

    // MARK: - Open / Close

    func open() {
        let options = seize
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        let ret = IOHIDDeviceOpen(device, options)
        guard ret == kIOReturnSuccess else {
            let pid = String(deviceSpec.productID, radix: 16, uppercase: true)
            print("\(deviceSpec.name) (0x\(pid)): failed to open (seize=\(seize)) — \(ret). "
                  + "Is another tablet driver running?")
            return
        }

        // IntuosV2: switch to full tablet mode; unlocks cursor/mouse button state.
        if deviceSpec.parser == .intuosV2 {
            sendWacomInputModeInit(device, tag: deviceSpec.name)
        }

        // IntuosV1: feature init activates the digitizer endpoint.
        // First byte of featureInit is the report ID.
        if var bytes = deviceSpec.featureInit {
            let reportID = CFIndex(bytes[0])
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, reportID, &bytes, bytes.count)
        }

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            WacomUniversalDevice.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - C callback

    private static let reportCallback: IOHIDReportCallback = { ctx, _, _, _, _, report, length in
        guard let ctx else { return }
        Unmanaged<WacomUniversalDevice>.fromOpaque(ctx).takeUnretainedValue()
            .handleReport(report: report, length: length)
    }

    // MARK: - Report dispatch

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        let results = decoder.decode(report: report, length: length, spec: spec, state: &state)
        for result in results {
            switch result {
            case .none:
                break
            case .pen(let point):
                onTablet(point)
            case .toolEnter(let identity):
                onToolEnter?(identity)
            case .aux(let buttons):
                onAux?(buttons)
            case .wireless(let ws):
                switch ws {
                case .active:           break
                case .lost:             print("\(deviceSpec.name): wireless link lost")
                case .lowBattery:       print("\(deviceSpec.name): battery critically low")
                case .unknown:          break
                }
            }
        }
    }
}
