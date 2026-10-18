// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later


import AppKit
import SwiftUI
import TabletKit

// The Buttons pane's pen section: the pen diagram and its button rows.
extension ButtonMappingView {
    @ViewBuilder
    func penButtonsSection(lb: LiveButtonState) -> some View {
        let toolSpec = activeToolSpec
        let isMouse = toolSpec?.toolType == .mouse
        let btnCount = Self.penButtonCount(tool: toolSpec, device: spec)
        let hasWheel = toolSpec?.hasWheel == true

        Section {
            // Tip — only for non-mouse tools
            if !isMouse {
                buttonRow(
                    String(localized: "Tip", comment: "Pen tip button row label in Buttons tab"),
                    isActive: lb.tipDown,
                    binding: tipBinding,
                    modeNames: ringModeNames, isMechanicalDialHardware: hasMechanicalDial,
                    recordRequestToken: penRecordTokens[0])
            }

            // Eraser — only for non-mouse tools
            if !isMouse {
                buttonRow(
                    String(localized: "Eraser", comment: "Eraser button row label in Buttons tab"),
                    isActive: lb.eraserDown,
                    binding: eraserBinding,
                    offersEraser: true,
                    modeNames: ringModeNames, isMechanicalDialHardware: hasMechanicalDial,
                    recordRequestToken: penRecordTokens[1])
                .disabled(!penHasEraser)
                .help(penHasEraser ? "" : String(localized: "This pen has no eraser.", comment: "Tooltip on the greyed-out Eraser row in Buttons tab"))
            }

            // Button 1
            if btnCount >= 1 {
                buttonRow(
                    Self.penButtonLabel(1, count: btnCount, isMouse: isMouse),
                    isActive: lb.button1Down,
                    binding: pen1Binding,
                    offersEraser: !isMouse,
                    modeNames: ringModeNames, isMechanicalDialHardware: hasMechanicalDial,
                    recordRequestToken: penRecordTokens[2])
            }
            // Button 2
            if btnCount >= 2 {
                buttonRow(
                    Self.penButtonLabel(2, count: btnCount, isMouse: isMouse),
                    isActive: lb.button2Down,
                    binding: pen2Binding,
                    offersEraser: !isMouse,
                    modeNames: ringModeNames, isMechanicalDialHardware: hasMechanicalDial,
                    recordRequestToken: penRecordTokens[3])
            }
            // Button 3
            if btnCount >= 3 {
                buttonRow(
                    Self.penButtonLabel(3, count: btnCount, isMouse: isMouse),
                    isActive: lb.button3Down,
                    binding: pen3Binding,
                    offersEraser: !isMouse,
                    modeNames: ringModeNames, isMechanicalDialHardware: hasMechanicalDial,
                    recordRequestToken: penRecordTokens[4])
            }
            // Button 4
            if btnCount >= 4 {
                buttonRow(
                    Self.penButtonLabel(4, count: btnCount, isMouse: isMouse),
                    isActive: lb.button4Down,
                    binding: pen4Binding,
                    modeNames: ringModeNames, isMechanicalDialHardware: hasMechanicalDial)
            }
            // Button 5
            if btnCount >= 5 {
                buttonRow(
                    Self.penButtonLabel(5, count: btnCount, isMouse: isMouse),
                    isActive: lb.button5Down,
                    binding: pen5Binding,
                    modeNames: ringModeNames, isMechanicalDialHardware: hasMechanicalDial)
            }

            // Wheel row — airbrush fingerwheel or scroll wheel
            if hasWheel {
                buttonRow(Self.wheelLabel(tool: toolSpec), isActive: false, binding: wheelBinding, modeNames: ringModeNames, isMechanicalDialHardware: hasMechanicalDial)
            }

            // Diagram row: no label column; transparent so the section
            // background shows through unchanged. Clicking a part starts
            // recording in its binding row — parts whose row isn't shown
            // (mouse tools, missing buttons) stay inert.
            PenDiagramView(liveButtons: lb, recipe: PenRecipe(tool: toolSpec, buttonCount: isMouse ? 3 : btnCount, hasEraser: penHasEraser), onPartTap: { part in
                switch part {
                case .tip: if !isMouse { penRecordTokens[0] += 1 }
                case .eraser: if !isMouse { penRecordTokens[1] += 1 }
                case .button1: if btnCount >= 1 { penRecordTokens[2] += 1 }
                case .button2: if btnCount >= 2 { penRecordTokens[3] += 1 }
                case .button3: if btnCount >= 3 { penRecordTokens[4] += 1 }
                }
            }, enabledParts: {
                var parts: Set<PenDiagramView.Part> = []
                if !isMouse { parts.insert(.tip); parts.insert(.eraser) }
                if btnCount >= 1 { parts.insert(.button1) }
                if btnCount >= 2 { parts.insert(.button2) }
                if btnCount >= 3 { parts.insert(.button3) }
                return parts
            }())
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 64)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
        } header: {
            PaneSectionHeader(isMouse ? "Mouse Buttons" : "Pen Buttons") {
                ToolNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
            }
        }
    }
}
