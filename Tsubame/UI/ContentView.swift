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
                    DictionaryImportProgressView(
                        title: model.importProgressText ?? "Importing…",
                        detail: model.importProgressDetail,
                        fraction: model.importProgressFraction
                    )
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
                        ForEach(
                            Array(model.installedDictionaries.enumerated()),
                            id: \.element.id
                        ) { priorityIndex, dictionary in
                            DictionaryRow(
                                dictionary: dictionary,
                                priority: priorityIndex + 1,
                                isActive: model.enabledDictionaryIDs.contains(dictionary.id),
                                canMoveUp: priorityIndex > 0,
                                canMoveDown: priorityIndex < model.installedDictionaries.count - 1,
                                activate: { model.toggleDictionary(id: dictionary.id) },
                                moveUp: { model.moveDictionary(id: dictionary.id, offset: -1) },
                                moveDown: { model.moveDictionary(id: dictionary.id, offset: 1) }
                            )
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
            VStack(spacing: 12) {
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

                if model.developerModeEnabled {
                    Divider()
                    HStack {
                        Button {
                            model.openDictionariesFolder()
                        } label: {
                            Label("Open Dictionaries Folder", systemImage: "folder")
                        }
                        Spacer()
                    }
                }
            }
            .padding(4)
        }
    }

    private func chooseDictionarySource() {
        let panel = NSOpenPanel()
        panel.title = "Import Yomitan Dictionaries"
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip]

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.importDictionaries(from: panel.urls)
    }
}

private struct DictionaryImportProgressView: View {
    let title: String
    let detail: String?
    let fraction: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    if let fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct DictionaryRow: View {
    let dictionary: InstalledDictionaryRecord
    let priority: Int
    let isActive: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let activate: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(priority)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityLabel("Priority \(priority)")
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
            VStack(spacing: 0) {
                Button(action: moveUp) {
                    Image(systemName: "chevron.up")
                        .frame(width: 18, height: 14)
                }
                .disabled(!canMoveUp)
                .help("Increase Priority")
                .accessibilityLabel("Increase Priority")

                Button(action: moveDown) {
                    Image(systemName: "chevron.down")
                        .frame(width: 18, height: 14)
                }
                .disabled(!canMoveDown)
                .help("Decrease Priority")
                .accessibilityLabel("Decrease Priority")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

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
