import TabletKit

/// The parts of `DeviceRouter`'s interface decision that need no IOKit, so
/// tools/tests/interface-routing-tests can replay captured descriptors.
enum InterfaceRouting {

    typealias UsagePair = (page: Int, usage: Int)

    /// True if any top-level collection is a digitizer pen (0x0D/0x02), or
    /// with `vendorPage`, Wacom's vendor pen collection (0xFF0D/0x01).
    static func isPenCollection(in pairs: [UsagePair], vendorPage: Bool = false) -> Bool {
        let pen = vendorPage ? (page: 0xFF0D, usage: 0x01) : (page: 0x0D, usage: 0x02)
        return pairs.contains { $0.page == pen.page && $0.usage == pen.usage }
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
        let isCintiqV1 = spec.parser == .cintiqV1
        let deferrablePage = isCintiqV1 ? 0xFF00 : 0x01
        // Pen displays like the DTH-167 have no 0xFF00 sibling: their one
        // interface leads with page 0x01 but also declares the pen
        // collection. Deferring it waited for a sibling that never comes.
        // The Cintiq 13HD Touch does the same with Wacom's vendor pen
        // page; the PTH-860 carries that page on 0x01 too but must defer.
        let isPenInterface = !isCintiqV1 && (isPenCollection(in: pairs)
            || (spec.parser == .intuosV1 && isPenCollection(in: pairs, vendorPage: true)))
        return !isBLE && spec.seizeUSB && usagePage == deferrablePage && !isPenInterface
    }
}
