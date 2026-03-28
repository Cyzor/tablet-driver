import Foundation
import AppKit

// MARK: - Four-char code helper

private func aeFourCC(_ s: StaticString) -> UInt32 {
    let b = s.utf8Start
    return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
}

// MARK: - Wacom Apple Events constants
//
// These mirror the Wacom ICBT (WacomTabletDriver) Apple Events suite.
//
// ⚠ kAEWacomSuite, kAESendTabletEvent, kAETabletCountProp,
//   kAEEventTypeProp, kAEEventTypeProx have NOT been confirmed against the
//   closed Wacom SDK.  Update after sniffing real traffic if Adobe still fails.

private let kAEWacomSuite:      AEEventClass = aeFourCC("WaCm")   // ⚠ needs verification
private let kAEGetDataID:       AEEventID    = aeFourCC("getd")
private let kAECreateElementID: AEEventID    = aeFourCC("crel")
private let kAEDeleteElementID: AEEventID    = aeFourCC("delo")
private let kAESendTabletEvent: AEEventID    = aeFourCC("snte")   // ⚠ needs verification

private let kAETabletCountProp: AEKeyword    = aeFourCC("pTbC")   // ⚠ needs verification
private let kAEEventTypeProp:   AEKeyword    = aeFourCC("eTyp")   // ⚠ needs verification
private let kAEEventTypeProx:   OSType       = aeFourCC("ePrx")   // ⚠ needs verification
// Any event-type value other than kAEEventTypeProx triggers a pointer replay.

// Distributed notification names posted to MockTab to trigger event replay.
private let kReplayPointer   = "com.cyzor.mocktab.shim.replayPointer"
private let kReplayProximity = "com.cyzor.mocktab.shim.replayProximity"

// MARK: -

/// Registers Wacom Apple Events handlers via NSAppleEventManager and responds
/// to Adobe's IPC queries.
///
/// Adobe Photoshop / Illustrator send a `pTabletCount` getd query on startup
/// to verify a Wacom driver is running (bundle ID `com.wacom.TabletDriver`).
/// If the reply count is non-zero, Adobe enables its native tablet code path.
///
/// Subsequently, Adobe sends `crel cCtx` to create a context, then periodically
/// sends `snte` (eSendTabletEvent) requesting a replay of the last tablet event.
/// Those requests are forwarded to MockTab via NSDistributedNotificationCenter
/// so MockTab can re-inject the cached HID event.
final class WacomAppleEventHandler: NSObject {

    private var contexts: [pid_t: Int] = [:]
    private var nextContextID = 1

    // MARK: - Installation

    func install() {
        let mgr = NSAppleEventManager.shared()

        mgr.setEventHandler(self,
            andSelector: #selector(handleGetData(_:withReplyEvent:)),
            forEventClass: kAEWacomSuite,
            andEventID: kAEGetDataID)

        mgr.setEventHandler(self,
            andSelector: #selector(handleCreateElement(_:withReplyEvent:)),
            forEventClass: kAEWacomSuite,
            andEventID: kAECreateElementID)

        mgr.setEventHandler(self,
            andSelector: #selector(handleDeleteElement(_:withReplyEvent:)),
            forEventClass: kAEWacomSuite,
            andEventID: kAEDeleteElementID)

        mgr.setEventHandler(self,
            andSelector: #selector(handleSendTabletEvent(_:withReplyEvent:)),
            forEventClass: kAEWacomSuite,
            andEventID: kAESendTabletEvent)

        print("WacomShim: Apple Events handlers installed (suite='WaCm')")
    }

    // MARK: - Context cleanup (called from ShimApp on app termination)

    func removeContext(for pid: pid_t) {
        contexts.removeValue(forKey: pid)
    }

    // MARK: - Handler: getd (tablet count / context property queries)

    @objc private func handleGetData(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return }

        // Property code: either the descriptor itself is a typeType, or it is an
        // object specifier whose property keyword is in keyAEKeyData.
        let propCode: AEKeyword
        if direct.descriptorType == typeType {
            propCode = direct.typeCodeValue
        } else {
            propCode = direct.paramDescriptor(forKeyword: AEKeyword(keyAEKeyData))?.typeCodeValue ?? AEKeyword(0)
        }

        switch propCode {
        case kAETabletCountProp:
            // Signal that one tablet is connected.
            reply.setDescriptor(NSAppleEventDescriptor(int32: 1),
                                forKeyword: keyDirectObject)
        default:
            break
        }
    }

    // MARK: - Handler: crel (create drawing context)

    @objc private func handleCreateElement(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        let pid   = senderPID(of: event)
        let ctxID = nextContextID
        nextContextID += 1
        if pid != 0 { contexts[pid] = ctxID }

        reply.setDescriptor(NSAppleEventDescriptor(int32: Int32(ctxID)),
                            forKeyword: keyDirectObject)
    }

    // MARK: - Handler: delo (delete drawing context)

    @objc private func handleDeleteElement(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        let pid = senderPID(of: event)
        if pid != 0 { contexts.removeValue(forKey: pid) }
    }

    // MARK: - Handler: snte (eSendTabletEvent — event replay request)

    @objc private func handleSendTabletEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        let eventType = event.paramDescriptor(forKeyword: kAEEventTypeProp)?.typeCodeValue ?? 0

        let dn = DistributedNotificationCenter.default()
        if eventType == kAEEventTypeProx {
            dn.postNotificationName(
                NSNotification.Name(kReplayProximity),
                object: nil, userInfo: nil,
                deliverImmediately: true)
        } else {
            dn.postNotificationName(
                NSNotification.Name(kReplayPointer),
                object: nil, userInfo: nil,
                deliverImmediately: true)
        }
    }

    // MARK: - Helpers

    private func senderPID(of event: NSAppleEventDescriptor) -> pid_t {
        guard let pidDesc = event.attributeDescriptor(forKeyword: keySenderPIDAttr) else {
            return 0
        }
        return pid_t(pidDesc.int32Value)
    }
}
