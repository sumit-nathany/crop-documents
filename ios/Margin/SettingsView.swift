import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Crop") {
                    // Straighten/deskew toggle hidden for now — the deskew angle estimate hasn't
                    // held up on real device photos, despite passing verification on Mac twice
                    // (see ios/HANDOFF.md). Re-enable once there's an on-device verification
                    // loop; CropSettings.straighten still exists and defaults to false meanwhile.
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
