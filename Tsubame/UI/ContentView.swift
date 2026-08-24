import AppKit
import SwiftUI
import TsubameCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tsubame")
                .font(.title2.bold())

            HStack {
                Button("Choose dictionary.sqlite…", action: chooseDatabase)

                Text(model.databaseURL?.lastPathComponent ?? "No database selected")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack {
                Label(
                    model.permissionStatus == .granted
                        ? "Accessibility granted"
                        : "Accessibility required",
                    systemImage: model.permissionStatus == .granted
                        ? "checkmark.shield"
                        : "exclamationmark.shield"
                )
                .foregroundStyle(model.permissionStatus == .granted ? .green : .orange)

                Spacer()

                if model.permissionStatus == .denied {
                    Button("Open Accessibility Settings") {
                        model.requestAccessibilityPermission()
                    }
                }

                Text("Capture: \(GlobalHotKeyMonitor.displayName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("Japanese text", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.runManualLookup)

                Button("Lookup", action: model.runManualLookup)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canRunManualLookup)
            }

            Text(model.status)
                .font(.callout)
                .foregroundStyle(model.entries.isEmpty ? .secondary : .primary)

            if let matchedRange = model.matchedRange {
                Text("Matched UTF-8 range: \(matchedRange.start)..<\(matchedRange.end)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            List(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.reading.isEmpty
                        ? entry.expression
                        : "\(entry.expression) 【\(entry.reading)】")
                        .font(.headline)

                    ForEach(entry.definitions, id: \.position) { definition in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(definition.position + 1).")
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)

                            Text(definition.text ?? "Structured definition")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .overlay {
                if model.databaseURL != nil, model.entries.isEmpty {
                    ContentUnavailableView(
                        "No results yet",
                        systemImage: "character.book.closed"
                    )
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            model.start()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.refreshPermissionStatus()
        }
    }

    private func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.title = "Choose an imported Tsubame dictionary"
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        model.openDictionary(at: selectedURL)
    }
}

#Preview {
    ContentView(model: AppModel())
}
