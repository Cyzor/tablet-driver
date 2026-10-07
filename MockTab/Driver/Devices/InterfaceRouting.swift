import TabletKit

/// The parts of `DeviceRouter`'s interface decision that need no IOKit, so
/// tools/tests/interface-routing-tests can replay captured descriptors.
enum InterfaceRouting {

    typealias UsagePair = (page: Int, usage: Int)

    /// True if any top-level collection is a digitizer pen (0x0D/0x02).
    static func isPenCollection(in pairs: [UsagePair]) -> Bool {
        pairs.contains { $0.page == 0x0D && $0.usage == 0x02 }
    }

    /// Whether a registered device's interface waits for a sibling to create
    /// the driver.
    ///
    /// IntuosV2 (PTH-x60/x80): vendor interface 0xFF00 is primary (init via
    /// the InputMode element). Interface 0x01 is deferred and registered as a
    /// secondary without seizure; seizing 0x01 stops IntuosV2 firmware from
    /// sending pen reports.
    ///
    /// CintiqV1 (DTK-2400 etc): interface 0x01 is the pen digitizer (reports
    /// 0x02, 0x0C) and gets the driver. 0xFF00 carries only the periodic 0x80
    /// status report, so it defers until 0x01 has the driver.
    static func shouldDefer(
        spec: WacomDeviceSpec, usagePage: Int, isBLE: Bool, pairs: [UsagePair]
    ) -> Bool {
        guard !isBLE, spec.seizeUSB else { return false }
        switch spec.parser {
        case .cintiqV1:
            return usagePage == 0xFF00
        case .intuosV2:
            // Pen displays like the DTH-167 have no 0xFF00 sibling: their one
            // interface leads with page 0x01 but also declares the pen
            // collection. Deferring it waited for a sibling that never comes.
            return usagePage == 0x01 && !isPenCollection(in: pairs)
        default:
            // Only the families above have a sibling to wait for. Deferring
            // any other family stranded single-interface devices such as the
            // DTU-1031, DTU-2231, and Cintiq 13HD Touch.
            return false
        }
    }
}
