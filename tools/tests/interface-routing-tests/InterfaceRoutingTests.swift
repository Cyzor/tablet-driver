import Foundation
import TabletKit

// Replays captured interface descriptors through InterfaceRouting.shouldDefer.
// A registered device whose every interface defers never gets a driver; that
// was the DTH-167 and Cintiq 13HD Touch bug.

struct Device: Decodable {
    let productID: String
    let transport: String
    let interfaces: [[[Int]]]
}

@main
enum InterfaceRoutingTests {
    static func main() throws {
        let here = URL(fileURLWithPath: CommandLine.arguments[1])
        let corpus = try JSONDecoder().decode([Device].self, from: Data(contentsOf: here))

        // Interfaces that must defer: seizing 0x01 on these stops pen reports.
        let mustDefer: Set<String> = ["0x0357 USB 0x1", "0x0358 USB 0x1"]

        var failures = 0, checked = 0
        for d in corpus {
            let pid = Int(d.productID.dropFirst(2), radix: 16)!
            guard pid != 0x0084,  // dongle: routed before the registry
                  !WacomDeviceRegistry.touchCompanionPIDs.contains(pid),
                  let spec = WacomDeviceRegistry.spec(for: pid),
                  spec.maxX > 0 || spec.buttonCount > 0
            else { continue }
            checked += 1
            let isBLE = d.transport.hasPrefix("Bluetooth")
            var drivers = 0
            for tops in d.interfaces {
                let pairs = tops.map { (page: $0[0], usage: $0[1]) }
                let page = pairs.first?.page ?? 0
                let deferred = InterfaceRouting.shouldDefer(
                    spec: spec, usagePage: page, isBLE: isBLE, pairs: pairs)
                if !deferred { drivers += 1 }
                let key = "\(d.productID) \(d.transport) 0x\(String(page, radix: 16))"
                if mustDefer.contains(key) && !deferred {
                    print("FAIL \(spec.name) (\(key)): must defer")
                    failures += 1
                }
            }
            if drivers == 0 {
                print("FAIL \(spec.name) (\(d.productID) \(d.transport)): every interface defers")
                failures += 1
            }
        }

        if failures > 0 { exit(1) }
        print("ok — \(checked) devices routed")
    }
}
