import AppKit
import SwiftUI
import TsubameCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.onboardingCompleted ? "Tsubame Settings" : "Welcome to Tsubame")
                        .font(.largeTitle.bold())
                    Text("Import a dictionary, grant Accessibility access, then select text anywhere and press \(GlobalHotKeyMonitor.displayName).")
                        .foregroundStyle(.secondary)
                }

                dictionarySection
                accessibilitySection
                AnkiSettingsView(model: model.ankiSettings)
                developerSection

                HStack(alignment: .firstTextBaseline) {
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    if !model.onboardingCompleted, model.canFinishOnboarding {
                        Button("Finish Setup") {
                            model.finishOnboarding()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 640, minHeight: 520)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.refreshPermissionStatus()
        }
    }

    private var dictionarySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dictionaries")
                            .font(.headline)
                        Text("Yomitan ZIP archives and unpacked dictionary folders are installed into Tsubame's Application Support directory.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import Dictionary…", action: chooseDictionarySource)
                        .disabled(model.isImportingDictionary)
                }

                if model.isImportingDictionary {
                    VStack(alignment: .leading, spacing: 6) {
                        if let fraction = model.importProgressFraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(model.importProgressText ?? "Importing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.isLoadingLibrary {
                    ProgressView("Loading installed dictionaries…")
                        .controlSize(.small)
                } else if model.installedDictionaries.isEmpty {
                    ContentUnavailableView(
                        "No dictionaries installed",
                        systemImage: "books.vertical",
                        description: Text("Import a Yomitan dictionary to enable system-wide lookup.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 130)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.installedDictionaries) { dictionary in
                            DictionaryRow(
                                dictionary: dictionary,
                                isActive: model.enabledDictionaryIDs.contains(dictionary.id)
                            ) {
                                model.toggleDictionary(id: dictionary.id)
                            }
                            if dictionary.id != model.installedDictionaries.last?.id {
                                Divider()
                            }
                        }
                    }
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(4)
        }
    }

    private var accessibilitySection: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: model.permissionStatus == .granted
                    ? "checkmark.shield.fill"
                    : "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(model.permissionStatus == .granted ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility")
                        .font(.headline)
                    Text(model.permissionStatus == .granted
                        ? "Tsubame can read the text selection in the frontmost application."
                        : "Required to read selected text and position the lookup popup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.permissionStatus == .denied {
                    Button("Open System Settings") {
                        model.requestAccessibilityPermission()
                    }
                }
            }
            .padding(4)
        }
    }

    private var developerSection: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Developer mode")
                        .font(.headline)
                    Text("Show capture, lookup, presentation, and total latency in the popup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $model.developerModeEnabled)
                    .labelsHidden()
            }
            .padding(4)
        }
    }

    private func chooseDictionarySource() {
        let panel = NSOpenPanel()
        panel.title = "Import a Yomitan dictionary"
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        model.importDictionary(from: sourceURL)
    }
}

private struct DictionaryRow: View {
    let dictionary: InstalledDictionaryRecord
    let isActive: Bool
    let activate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "book.closed.fill" : "book.closed")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(dictionary.manifest.title)
                    .font(.body.weight(.medium))
                Text("\(dictionary.manifest.termCount.formatted()) terms · revision \(dictionary.manifest.revision)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { isActive },
                set: { _ in activate() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

#Preview {
    ContentView(model: AppModel())
}
