import SwiftUI

struct SpeechSettingsView: View {
    @Bindable var model: SpeechSettingsModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pronunciation")
                            .font(.headline)
                        Text("Generate Japanese audio locally using the voices installed on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.enabled)
                        .labelsHidden()
                }

                if model.enabled {
                    Divider()
                    HStack(spacing: 10) {
                        Picker("Japanese voice", selection: $model.voiceIdentifier) {
                            Text("System Default").tag(Optional<String>.none)
                            ForEach(model.japaneseVoices) { voice in
                                Text(voice.displayName).tag(Optional(voice.id))
                            }
                        }
                        Slider(value: $model.rate, in: 0.8...1.2, step: 0.05) {
                            Text("Speed")
                        }
                        .frame(width: 130)
                        Text("\(model.rate, format: .number.precision(.fractionLength(2)))×")
                            .font(.caption.monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                        Button("Preview") {
                            model.preview()
                        }
                        .disabled(model.previewState == .generating || model.japaneseVoices.isEmpty)
                    }
                    if model.previewState == .generating {
                        ProgressView("Generating preview…")
                            .controlSize(.small)
                    } else if let message = model.previewMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("When an Anki field contains {audio}, this pronunciation is attached to the card and syncs as Anki media.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        }
    }
}
