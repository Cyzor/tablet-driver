import SwiftUI

struct ButtonMappingView: View {
    @ObservedObject var settings: TabletSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pen Buttons")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Side button 1").frame(width: 120, alignment: .leading)
                    actionPicker(value: Binding(
                        get: { ButtonAction(rawValue: settings.penButton1Action) ?? .rightClick },
                        set: { settings.penButton1Action = $0.rawValue }
                    ))
                }
                GridRow {
                    Text("Side button 2").frame(width: 120, alignment: .leading)
                    actionPicker(value: Binding(
                        get: { ButtonAction(rawValue: settings.penButton2Action) ?? .middleClick },
                        set: { settings.penButton2Action = $0.rawValue }
                    ))
                }
            }

            Divider()

            Text("Express Keys")
                .font(.headline)

            Text("Up to 8 express keys on the PTH-860 (PTH-851 has none).")
                .font(.caption)
                .foregroundStyle(.secondary)

            let actions = settings.expressKeyActions
            let paddedActions: [ButtonAction] = (0..<8).map { i in
                i < actions.count ? actions[i] : .none
            }

            ForEach(0..<8, id: \.self) { i in
                Grid(alignment: .leading, horizontalSpacing: 16) {
                    GridRow {
                        Text("Key \(i + 1)").frame(width: 60, alignment: .leading)
                        actionPicker(value: Binding(
                            get: { paddedActions[i] },
                            set: { newVal in
                                var updated = paddedActions
                                updated[i] = newVal
                                settings.expressKeyActions = updated
                            }
                        ))
                    }
                }
            }
        }
        .padding()
    }

    private func actionPicker(value: Binding<ButtonAction>) -> some View {
        Picker("", selection: value) {
            ForEach(ButtonAction.allCases) { action in
                Text(action.label).tag(action)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 180)
        .labelsHidden()
    }
}
