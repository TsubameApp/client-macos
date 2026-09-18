import AppKit
import SwiftUI
import TsubameCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isShowingLicense = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.onboardingCompleted ? "Tsubame Settings" : "Welcome to Tsubame")
                        .font(.largeTitle.bold())
                    Text("Import a dictionary, grant Accessibility access, then select text anywhere and press \(model.globalShortcut.displayName).")
                        .foregroundStyle(.secondary)
                }

                dictionarySection
                accessibilitySection
                globalShortcutSection
                AnkiSettingsView(model: model.ankiSettings)
                advancedSection

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

                Divider()
                aboutFooter
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
        .sheet(isPresented: $isShowingLicense) {
            LicenseView()
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
                        .disabled(model.isDictionaryLibraryBusy)
                }

                if model.isImportingDictionary {
                    DictionaryImportProgressView(
                        title: model.importProgressText ?? "Importing…",
                        detail: model.importProgressDetail,
                        fraction: model.importProgressFraction,
                        isCancelling: model.isCancellingDictionaryImport,
                        cancel: model.cancelDictionaryImport
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
                                isUpdating: model.updatingDictionaryID == dictionary.id,
                                isRemoving: model.removingDictionaryID == dictionary.id,
                                controlsDisabled: model.isDictionaryLibraryBusy,
                                activate: { model.toggleDictionary(id: dictionary.id) },
                                moveUp: { model.moveDictionary(id: dictionary.id, offset: -1) },
                                moveDown: { model.moveDictionary(id: dictionary.id, offset: 1) },
                                replace: { chooseReplacementSource(for: dictionary) },
                                remove: { model.removeDictionary(id: dictionary.id) }
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

    private var globalShortcutSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: model.isGlobalShortcutActive
                        ? "keyboard.badge.ellipsis"
                        : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(model.isGlobalShortcutActive ? Color.accentColor : .orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Global Shortcut")
                            .font(.headline)
                        Text("Runs a lookup for the selected text without changing the clipboard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    ShortcutRecorderView(
                        shortcut: model.globalShortcut,
                        isRecording: model.isRecordingGlobalShortcut,
                        beginRecording: model.beginGlobalShortcutRecording,
                        cancelRecording: model.cancelGlobalShortcutRecording,
                        commit: model.updateGlobalShortcut
                    )
                    .frame(width: 160)

                    Button("Reset to Default") {
                        model.resetGlobalShortcut()
                    }
                    .disabled(model.globalShortcut == .defaultLookup)
                }

                if let error = model.globalShortcutError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Global shortcut error: \(error)")
                } else {
                    Text(model.isGlobalShortcutActive
                        ? "Active"
                        : "The shortcut is not currently active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private var advancedSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Advanced")
                    .font(.headline)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Performance metrics")
                            .font(.body.weight(.medium))
                        Text("Show capture, lookup, presentation, and total latency in the popup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.developerModeEnabled)
                        .labelsHidden()
                }

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
            .padding(4)
        }
    }

    private var aboutFooter: some View {
        HStack(spacing: 6) {
            Text("Tsubame \(AppBuildInfo.current.displayVersion) (\(AppBuildInfo.configurationName))")
                .textSelection(.enabled)
            Text("·")
            Button("GPL-3.0-only") {
                isShowingLicense = true
            }
            .buttonStyle(.link)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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

    private func chooseReplacementSource(for dictionary: InstalledDictionaryRecord) {
        let panel = NSOpenPanel()
        panel.title = "Replace \(dictionary.manifest.title)"
        panel.prompt = "Choose Replacement"
        panel.message = "Choose a Yomitan ZIP archive or unpacked dictionary folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace \(dictionary.manifest.title)?"
        alert.informativeText = "Revision \(dictionary.manifest.revision) will be replaced using \(sourceURL.lastPathComponent). Enabled state and priority will be preserved. The current dictionary remains installed if validation fails or the update is cancelled."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        model.replaceDictionary(id: dictionary.id, from: sourceURL)
    }
}

private struct LicenseView: View {
    @Environment(\.dismiss) private var dismiss

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "GNU General Public License, version 3 only."
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tsubame License")
                    .font(.title2.bold())
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                Text(licenseText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}

private struct DictionaryImportProgressView: View {
    let title: String
    let detail: String?
    let fraction: Double?
    let isCancelling: Bool
    let cancel: () -> Void

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

            if isCancelling {
                ProgressView()
                    .controlSize(.small)
                    .help("Cancelling import")
            } else {
                Button("Cancel", role: .cancel, action: cancel)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

private struct DictionaryRow: View {
    let dictionary: InstalledDictionaryRecord
    let priority: Int
    let isActive: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let isUpdating: Bool
    let isRemoving: Bool
    let controlsDisabled: Bool
    let activate: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let replace: () -> Void
    let remove: () -> Void

    @State private var showsRemovalConfirmation = false

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
                .disabled(controlsDisabled || !canMoveUp)
                .help("Increase Priority")
                .accessibilityLabel("Increase Priority")

                Button(action: moveDown) {
                    Image(systemName: "chevron.down")
                        .frame(width: 18, height: 14)
                }
                .disabled(controlsDisabled || !canMoveDown)
                .help("Decrease Priority")
                .accessibilityLabel("Decrease Priority")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            if isUpdating {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Updating dictionary")
            } else {
                Button(action: replace) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(controlsDisabled)
                .help("Replace Dictionary")
                .accessibilityLabel("Replace Dictionary")
            }

            if isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Moving dictionary to Trash")
            } else {
                Button {
                    showsRemovalConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(controlsDisabled)
                .help("Move Dictionary to Trash")
                .accessibilityLabel("Move Dictionary to Trash")
            }

            Toggle("Enabled", isOn: Binding(
                get: { isActive },
                set: { _ in activate() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(controlsDisabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .alert(
            "Move \(dictionary.manifest.title) to Trash?",
            isPresented: $showsRemovalConfirmation
        ) {
            Button("Move to Trash", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The installed dictionary bundle will be removed from Tsubame and can be recovered from the Trash.")
        }
    }
}

#Preview {
    ContentView(model: AppModel())
}
