import XCTest
@testable import TabletKit

final class WacomDeviceRegistryTests: XCTestCase {

    // MARK: - spec(forProductID:productString:) precedence

    func testStringMatchWinsOverCatchAll() {
        let spec = WacomDeviceRegistry.spec(
            forProductID: 0x0357, productString: "Intuos Pro M (PTH-660)")
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.productID, 0x0357)
    }

    func testFallsBackToCatchAllWhenStringDoesNotMatch() {
        // No real Wacom spec uses productStringMatch today, so any productString
        // should still resolve to the same catch-all entry.
        let withString = WacomDeviceRegistry.spec(
            forProductID: 0x0357, productString: "totally unrelated")
        let bare = WacomDeviceRegistry.spec(for: 0x0357)
        XCTAssertEqual(withString?.productID, bare?.productID)
        XCTAssertEqual(withString?.name, bare?.name)
    }

    func testReturnsNilForUnknownPID() {
        XCTAssertNil(WacomDeviceRegistry.spec(forProductID: 0xFFFF, productString: nil))
        XCTAssertNil(WacomDeviceRegistry.spec(forProductID: 0xFFFF, productString: "anything"))
    }

    func testNilProductStringBehavesLikeLegacyLookup() {
        let viaOverload = WacomDeviceRegistry.spec(forProductID: 0x0358, productString: nil)
        let viaLegacy = WacomDeviceRegistry.spec(for: 0x0358)
        XCTAssertEqual(viaOverload?.productID, viaLegacy?.productID)
    }

    // MARK: - lpi derivation

    func testLPIIsNilWhenDimensionsMissing() {
        // PenPartner (0x0003) is one of the older entries we don't have
        // confident mm dimensions for — the LPI standard for the PenPartner
        // era isn't documented and our maxX/maxY come from kernel sources
        // without a paired physical-dimension reference.  Keep this canary
        // pointed at an entry that's intentionally nil so a future backfill
        // pass that touches it has to think about it.
        let s = WacomDeviceRegistry.spec(for: 0x0003)
        XCTAssertNotNil(s)
        XCTAssertNil(s?.activeWidthMM,
                     "If you just backfilled 0x0003, point this canary at "
                     + "another intentionally-nil PID (or delete the test).")
        XCTAssertNil(s?.lpi)
    }

    func testLPIDerivesFromVerifiedHardware() {
        // PTH-860: 62200 / 311.0 mm × 25.4 ≈ 5080 LPI on both axes —
        // matches the published Wacom Pro 2 sensor spec.
        guard let spec = WacomDeviceRegistry.spec(for: 0x0358),
              let lpi = spec.lpi else {
            return XCTFail("PTH-860 spec missing mm dimensions")
        }
        XCTAssertEqual(lpi.x, 5080, accuracy: 5)
        XCTAssertEqual(lpi.y, 5080, accuracy: 5)
    }

    func testLPIDerivesForCintiq24HD() {
        // DTK-2400: active area 519×324 mm; LPI lands in the Wacom Pro sensor
        // range (~5000–5200) on both axes.  Looser tolerance than PTH-860
        // because the Cintiq sensor is not exactly 5080 LPI.
        guard let spec = WacomDeviceRegistry.spec(for: 0x00F4),
              let lpi = spec.lpi else {
            return XCTFail("DTK-2400 spec missing mm dimensions")
        }
        XCTAssertEqual(lpi.x, 5113, accuracy: 25)
        XCTAssertEqual(lpi.y, 5143, accuracy: 25)
    }

    // MARK: - canonical PID normalization (sanity check on the file)

    func testCanonicalPIDCollapsesBTToUSBForPTH660() {
        XCTAssertEqual(WacomDeviceRegistry.canonicalProductID(for: 0x0360), 0x0357)
        XCTAssertEqual(WacomDeviceRegistry.canonicalProductID(for: 0x0359), 0x0357)
    }
}
