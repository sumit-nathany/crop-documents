import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Crop") {
                    // Straighten/deskew toggle hidden for now — the auto-rotate angle estimate
                    // isn't reliable yet on real device photos (see ios/HANDOFF.md). Re-enable
                    // once that's re-verified; CropSettings.straighten still exists and defaults
                    // to false in the meantime.
                    HStack {
                        Text("Border")
                        Spacer()
                        Text("\(Int(store.settings.expansionPercent))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $store.settings.expansionPercent, in: 0...12, step: 1)

                    Toggle("Enhance", isOn: $store.settings.enhance)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.persistSettings()
                        dismiss()
                    }
                }
            }
            .onDisappear { store.persistSettings() }
        }
    }
}
