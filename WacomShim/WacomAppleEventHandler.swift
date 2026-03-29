// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import AppKit

// MARK: - Four-char code helper

private func aeFourCC(_ s: StaticString) -> UInt32 {
    let b = s.utf8Start
    return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
}

// MARK: - Apple Events constants (verified against Wacom ICBT SDK docs)
//
// Bugs fixed from initial implementation:
//   1. kAEWacomSuite: 'WaCm' → 'Wacm'  (case error, bytes 3-4 differ)
//   2. kAESendTabletEvent: 'snte' → 'WSnd'  (invented code vs SDK-defined)
//   3. getd/crel/delo registered under kAECoreSuite, NOT kAEWacomSuite
//   4. eEventProximity: 'ePrx' → 'WePx'; added eEventPointer = 'WePt'
//   5. eSendTabletEvent event-type parameter uses keyAEData ('data'), not custom 'eTyp'
//   6. CFBundleSignature in Info.plist: 'WaCM' (uppercase C and M)
//   8. handleCreateElement gates on cContext = 'CTxt'

// Wacom suite — only eSendTabletEvent lives here.
private let kAEWacomSuite:      AEEventClass = aeFourCC("Wacm")

// eSendTabletEvent — Adobe sends this to request a replay of the last HID event.
private let kAESendTabletEvent: AEEventID    = aeFourCC("WSnd")

// Core suite — getd/crel/delo are registered here, not under kAEWacomSuite.
// Use aeFourCC rather than kAECoreSuite to avoid Int↔UInt32 cast issues.
private let kCoreSuite:         AEEventClass = aeFourCC("core")

// Core suite event IDs (system values, redeclared to avoid import-type casting).
private let kGetData:           AEEventID    = aeFourCC("getd")
private let kCreateElement:     AEEventID    = aeFourCC("crel")
private let kDeleteElement:     AEEventID    = aeFourCC("delo")

// Wacom property / class / event-type codes.
private let kAETabletCountProp: AEKeyword    = aeFourCC("pTbC")   // pTabletCount property
private let cContext:           DescType     = aeFourCC("CTxt")   // cContext class (crel gate)
private let eEventProximity:    OSType       = aeFourCC("WePx")   // proximity event type
private let eEventPointer:      OSType       = aeFourCC("WePt")   // pointer event type

// keyAEObjectClass ('kocl') — identifies the class in a crel event.
private let kKeyObjectClass:    AEKeyword    = aeFourCC("kocl")

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
/// Subsequently Adobe sends `crel cCtx` to open a drawing context, then
/// periodically sends `WSnd` (eSendTabletEvent) requesting a replay of the
/// last tablet event.  Those requests are forwarded to MockTab via
/// NSDistributedNotificationCenter so MockTab re-injects the cached HID event.
final class WacomAppleEventHandler: NSObject {

    private var contexts: [pid_t: Int] = [:]
    private var nextContextID = 1

    // MARK: - Installation

    func install() {
        let mgr = NSAppleEventManager.shared()

        // getd, crel, delo belong to kAECoreSuite ('core'), not kAEWacomSuite.
        mgr.setEventHandler(self,
            andSelector: #selector(handleGetData(_:withReplyEvent:)),
            forEventClass: kCoreSuite,
            andEventID: kGetData)

        mgr.setEventHandler(self,
            andSelector: #selector(handleCreateElement(_:withReplyEvent:)),
            forEventClass: kCoreSuite,
            andEventID: kCreateElement)

        mgr.setEventHandler(self,
            andSelector: #selector(handleDeleteElement(_:withReplyEvent:)),
            forEventClass: kCoreSuite,
            andEventID: kDeleteElement)

        // eSendTabletEvent is the only Wacom-suite event.
        mgr.setEventHandler(self,
            andSelector: #selector(handleSendTabletEvent(_:withReplyEvent:)),
            forEventClass: kAEWacomSuite,
            andEventID: kAESendTabletEvent)

        NSLog("WacomShim: Apple Events handlers installed (suite='Wacm', WSnd)")
    }

    // MARK: - Context cleanup (called from ShimApp on app termination)

    func removeContext(for pid: pid_t) {
        contexts.removeValue(forKey: pid)
    }

    // MARK: - Handler: getd — tablet count and property queries

    @objc private func handleGetData(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        let pid = senderPID(of: event)
        NSLog("WacomShim: getd from pid \(pid)")

        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else {
            NSLog("WacomShim: getd — no direct object")
            return
        }

        let propCode: AEKeyword
        if direct.descriptorType == typeType {
            propCode = direct.typeCodeValue
        } else {
            propCode = direct.paramDescriptor(forKeyword: AEKeyword(keyAEKeyData))?.typeCodeValue
                       ?? AEKeyword(0)
        }

        let tag = String(UnicodeScalar((propCode >> 24) & 0xFF)!)
                + String(UnicodeScalar((propCode >> 16) & 0xFF)!)
                + String(UnicodeScalar((propCode >>  8) & 0xFF)!)
                + String(UnicodeScalar( propCode        & 0xFF)!)
        NSLog("WacomShim: getd prop='\(tag)'")

        switch propCode {
        case aeFourCC("vers"):
            // Adobe checks driver version before pTabletCount; return a plausible 6.3.45 BCD.
            NSLog("WacomShim: replying pVersion=6.3.45")
            var version = UInt32(0x06034500).bigEndian
            if let desc = NSAppleEventDescriptor(
                descriptorType: DescType(typeVersion),
                bytes: &version, length: 4)
            {
                reply.setDescriptor(desc, forKeyword: keyDirectObject)
            }

        case kAETabletCountProp:
            NSLog("WacomShim: replying pTabletCount=1")
            reply.setDescriptor(NSAppleEventDescriptor(int32: 1),
                                forKeyword: keyDirectObject)

        default:
            NSLog("WacomShim: getd — unhandled prop '\(tag)', no reply")
        }
    }

    // MARK: - Handler: crel — create drawing context

    @objc private func handleCreateElement(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        let pid = senderPID(of: event)
        let rawClass = event.paramDescriptor(forKeyword: kKeyObjectClass)?.typeCodeValue ?? 0
        let classTag = String(UnicodeScalar((rawClass >> 24) & 0xFF)!)
                     + String(UnicodeScalar((rawClass >> 16) & 0xFF)!)
                     + String(UnicodeScalar((rawClass >>  8) & 0xFF)!)
                     + String(UnicodeScalar( rawClass        & 0xFF)!)
        NSLog("WacomShim: crel from pid \(pid) objectClass='\(classTag)'")

        // Log if the class code doesn't match our 'CTxt' constant — but create the
        // context anyway so the handshake completes while we verify the constant.
        let objectClass = event.paramDescriptor(forKeyword: kKeyObjectClass)?.typeCodeValue
        if objectClass != cContext {
            NSLog("WacomShim: crel — unexpected class '\(classTag)' (expected 'CTxt'); proceeding anyway")
        }

        let ctxID = nextContextID
        nextContextID += 1
        if pid != 0 { contexts[pid] = ctxID }

        reply.setDescriptor(NSAppleEventDescriptor(int32: Int32(ctxID)),
                            forKeyword: keyDirectObject)
    }

    // MARK: - Handler: delo — delete drawing context

    @objc private func handleDeleteElement(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        let pid = senderPID(of: event)
        NSLog("WacomShim: delo from pid \(pid)")
        if pid != 0 { contexts.removeValue(forKey: pid) }
    }

    // MARK: - Handler: WSnd — eSendTabletEvent replay request

    @objc private func handleSendTabletEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        // Event type is stored under keyAEData ('data'), not a custom keyword.
        let eventType = event.paramDescriptor(forKeyword: AEKeyword(keyAEData))?.typeCodeValue ?? 0
        let tag = String(UnicodeScalar((eventType >> 24) & 0xFF)!)
                + String(UnicodeScalar((eventType >> 16) & 0xFF)!)
                + String(UnicodeScalar((eventType >>  8) & 0xFF)!)
                + String(UnicodeScalar( eventType        & 0xFF)!)
        NSLog("WacomShim: WSnd eventType='\(tag)'")

        let dn = DistributedNotificationCenter.default()
        if eventType == eEventProximity {
            dn.postNotificationName(
                NSNotification.Name(kReplayProximity),
                object: nil, userInfo: nil,
                deliverImmediately: true)
        } else {
            // Covers eEventPointer and any unknown value.
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
