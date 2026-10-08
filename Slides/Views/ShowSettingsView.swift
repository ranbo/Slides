import SwiftUI

struct ShowSettingsView: View {
    @Binding var settings: ShowSettings
    var onCopyAllMedia: () -> Void

    var body: some View {
        Form {
            Section("Photos") {
                LabeledContent("Default duration") {
                    SecondsField(value: $settings.slideDuration, range: ShowTimeline.minimumDuration...120)
                }
                LabeledContent("Cross-fade") {
                    SecondsField(value: $settings.crossfade, range: 0...5, step: 0.25)
                }
                LabeledContent("Default zoom") {
                    HStack(spacing: 4) {
                        TextField("", value: Binding(get: { (settings.zoom * 100).rounded() },
                                                     set: { settings.zoom = min(max($0, 0), 40) / 100 }),
                                  format: .number)
                            .frame(width: 52)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $settings.zoom, in: 0...0.4, step: 0.01).labelsHidden()
                        Text("%").foregroundStyle(.secondary)
                    }
                }
                Toggle("Fade in from black", isOn: $settings.fadeInFromBlack)
                Toggle("Fade out to black", isOn: $settings.fadeOutToBlack)
            }
            Section("Music") {
                LabeledContent("Fade out at end") {
                    SecondsField(value: $settings.musicFadeOut, range: 0...15)
                }
            }
            Section("Export") {
                Picker("Frame rate", selection: $settings.frameRate) {
                    ForEach([24, 25, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                LabeledContent("Size", value: "\(settings.outputWidth) × \(settings.outputHeight)")
            }
            Section {
                Toggle("Copy new photos and music into the document", isOn: $settings.copyMediaIntoDocument)
                Button("Copy All Media Into Document", action: onCopyAllMedia)
            } header: {
                Text("Media")
            } footer: {
                Text("Copies make the document self-contained, so it still works if the originals move or are deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}
