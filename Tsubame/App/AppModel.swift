import AppKit
import Foundation
import Observation
import OSLog
import TsubameCore

@MainActor
@Observable
final class AppModel {
    var query = "食べました"
    var developerModeEnabled: Bool {
        didSet {
            preferences.developerModeEnabled = developerModeEnabled
            popupController.setDeveloperModeEnabled(developerModeEnabled)
            TsubameLogging.lifecycle.notice(
                "Developer mode changed enabled=\(self.developerModeEnabled, privacy: .public)"
            )
        }
    }
    private(set) var onboardingCompleted: Bool
    private(set) var installedDictionaries: [InstalledDictionaryRecord] = []
    private(set) var enabledDictionaryIDs: Set<UUID> = []
    private(set) var dictionaryOrderIDs: [UUID] = []
    private(set) var isLoadingLibrary = false
    private(set) var isImportingDictionary = false
    private(set) var isCancellingDictionaryImport = false
    private(set) var updatingDictionaryID: UUID?
    private(set) var removingDictionaryID: UUID?
    private(set) var importProgressText: String?
    private(set) var importProgressDetail: String?
    private(set) var importProgressFraction: Double?
    private(set) var entries: [DictionaryEntry] = []
    private(set) var matchedRange: UTF8TextRange?
    private(set) var status = "Loading installed dictionaries…"
    private(set) var permissionStatus: AccessibilityPermissionStatus
    private(set) var globalShortcut: Shortcut
    private(set) var isGlobalShortcutActive = false
    private(set) var globalShortcutError: String?
    private(set) var isRecordingGlobalShortcut = false

    var onOnboardingCompleted: (() -> Void)?
    var onMainWindowRequired: (() -> Void)?
    var onGlobalShortcutChanged: ((Shortcut) -> Void)?

    @ObservationIgnored private let captureProvider: any CaptureProvider
    @ObservationIgnored private let permissionClient: AccessibilityPermissionClient
    @ObservationIgnored private let popupController: DictionaryPopupController
    @ObservationIgnored private let hotKeyMonitor: any GlobalHotKeyMonitoring
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let libraryService: DictionaryLibraryService
    @ObservationIgnored let ankiSettings: AnkiSettingsModel
    @ObservationIgnored private let ankiMining: AnkiMiningModel
    @ObservationIgnored private var dictionary: DictionaryCollection?
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    @ObservationIgnored private var manualLookupTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importSessionID: UUID?
    @ObservationIgnored private var nextRequestID: UInt64 = 0
    @ObservationIgnored private var currentRequestID: UInt64?
    @ObservationIgnored private var hasStarted = false

    init(
        captureProvider: any CaptureProvider = AccessibilityCaptureProvider(),
        permissionClient: AccessibilityPermissionClient = .init(),
        popupController: DictionaryPopupController = .init(),
        hotKeyMonitor: any GlobalHotKeyMonitoring = GlobalHotKeyMonitor(),
        preferences: AppPreferences = .init(),
        libraryService: DictionaryLibraryService = .init(),
        ankiSettings: AnkiSettingsModel = .init(),
        ankiMiningService: any AnkiMiningServing = AnkiMiningService()
    ) {
        self.captureProvider = captureProvider
        self.permissionClient = permissionClient
        self.popupController = popupController
        self.hotKeyMonitor = hotKeyMonitor
        self.preferences = preferences
        self.libraryService = libraryService
        self.ankiSettings = ankiSettings
        ankiMining = AnkiMiningModel(
            settings: ankiSettings,
            service: ankiMiningService
        )
        developerModeEnabled = preferences.developerModeEnabled
        onboardingCompleted = preferences.onboardingCompleted
        permissionStatus = permissionClient.status()
        globalShortcut = preferences.globalShortcut
        popupController.setDeveloperModeEnabled(developerModeEnabled)
        popupController.setAnkiMiningModel(ankiMining)
    }

    var shouldShowMainWindowOnLaunch: Bool {
        !onboardingCompleted
    }

    var canFinishOnboarding: Bool {
        !installedDictionaries.isEmpty
    }

    var canRunManualLookup: Bool {
        dictionary != nil && !query.isEmpty
    }

    var isDictionaryLibraryBusy: Bool {
        isLoadingLibrary || isImportingDictionary || removingDictionaryID != nil
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshPermissionStatus()
        let shortcutResult = hotKeyMonitor.start(shortcut: globalShortcut) { [weak self] in
            guard let self, !self.isRecordingGlobalShortcut else { return }
            self.triggerCapture()
        }
        switch shortcutResult {
        case .success:
            isGlobalShortcutActive = true
            globalShortcutError = nil
            preferences.globalShortcut = globalShortcut
        case .failure(let error):
            isGlobalShortcutActive = false
            globalShortcutError = error.localizedDescription
        }
        loadInstalledDictionaries()

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        TsubameLogging.lifecycle.notice(
            "Tsubame started version=\(version, privacy: .public) build=\(build, privacy: .public) debug=\(_isDebugAssertConfiguration(), privacy: .public)"
        )
    }

    func beginGlobalShortcutRecording() {
        isRecordingGlobalShortcut = true
        globalShortcutError = nil
    }

    func cancelGlobalShortcutRecording() {
        isRecordingGlobalShortcut = false
    }

    @discardableResult
    func updateGlobalShortcut(_ shortcut: Shortcut) -> Bool {
        switch hotKeyMonitor.update(shortcut: shortcut) {
        case .success:
            isRecordingGlobalShortcut = false
            globalShortcut = shortcut
            isGlobalShortcutActive = true
            globalShortcutError = nil
            preferences.globalShortcut = shortcut
            status = "Global shortcut changed to \(shortcut.displayName)."
            onGlobalShortcutChanged?(shortcut)
            return true
        case .failure(let error):
            let suffix = hotKeyMonitor.activeShortcut.map {
                " \($0.displayName) remains active."
            } ?? " No global shortcut is currently active."
            globalShortcutError = error.localizedDescription + suffix
            isGlobalShortcutActive = hotKeyMonitor.activeShortcut != nil
            return false
        }
    }

    func resetGlobalShortcut() {
        _ = updateGlobalShortcut(.defaultLookup)
    }

    func stop() {
        hotKeyMonitor.stop()
        isGlobalShortcutActive = false
    }

    func finishOnboarding() {
        guard canFinishOnboarding else { return }
        let wasIncomplete = !onboardingCompleted
        preferences.onboardingCompleted = true
        onboardingCompleted = true
        if wasIncomplete {
            TsubameLogging.lifecycle.notice("Onboarding completed")
            onOnboardingCompleted?()
        }
    }

    func refreshPermissionStatus() {
        let updated = permissionClient.status()
        if updated != permissionStatus {
            TsubameLogging.permission.notice(
                "Accessibility status changed status=\(updated.rawValue, privacy: .public)"
            )
        }
        permissionStatus = updated
    }

    func requestAccessibilityPermission() {
        permissionClient.requestAndOpenSystemSettings()
        refreshPermissionStatus()
        if permissionStatus == .denied {
            status = "Enable Tsubame in Privacy & Security → Accessibility, then return to the app."
        }
    }

    func importDictionaries(from sourceURLs: [URL]) {
        guard !isDictionaryLibraryBusy, !sourceURLs.isEmpty else { return }
        let sessionID = UUID()
        let sourceCount = sourceURLs.count
        let initiallyInstalledIDs = Set(installedDictionaries.map(\.id))
        importSessionID = sessionID
        isImportingDictionary = true
        isCancellingDictionaryImport = false
        importProgressText = sourceCount == 1
            ? sourceURLs[0].lastPathComponent
            : "Preparing dictionaries…"
        importProgressDetail = sourceCount == 1 ? "Starting import" : "0 of \(sourceCount) completed"
        importProgressFraction = 0
        status = sourceCount == 1
            ? "Importing \(sourceURLs[0].lastPathComponent)…"
            : "Importing \(sourceCount) dictionaries…"

        importTask = Task { [weak self] in
            guard let self else { return }
            defer { finishDictionaryImport(sessionID: sessionID) }

            var installedRecords: [InstalledDictionaryRecord] = []
            var failures: [(source: String, error: String)] = []

            do {
                for (offset, sourceURL) in sourceURLs.enumerated() {
                    try Task.checkCancellation()
                    let sourceIndex = offset + 1
                    let sourceName = sourceURL.lastPathComponent
                    importProgressText = sourceName
                    importProgressDetail = importProgressDescription(
                        sourceIndex: sourceIndex,
                        sourceCount: sourceCount,
                        detail: "Preparing"
                    )
                    importProgressFraction = Double(offset) / Double(sourceCount)

                    let progress: DictionaryImportProgressHandler = { [weak self] event in
                        Task { @MainActor in
                            guard let self,
                                  self.importSessionID == sessionID,
                                  !self.isCancellingDictionaryImport else { return }
                            self.applyImportProgress(
                                event,
                                sourceName: sourceName,
                                sourceIndex: sourceIndex,
                                sourceCount: sourceCount
                            )
                        }
                    }

                    do {
                        let installed = try await installDictionary(
                            from: sourceURL,
                            progress: progress
                        )
                        installedRecords.append(installed)
                        TsubameLogging.dictionaryLibrary.notice(
                            "Dictionary installed id=\(installed.id.uuidString, privacy: .public) title=\(installed.manifest.title, privacy: .public)"
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failures.append((sourceName, error.localizedDescription))
                        TsubameLogging.dictionaryLibrary.error(
                            "Dictionary import failed source=\(sourceName, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                }

                if !installedRecords.isEmpty {
                    try Task.checkCancellation()
                    let loaded = try await libraryService.load()
                    try Task.checkCancellation()
                    applyInstalledDictionaries(
                        loaded,
                        appending: installedRecords.map(\.id)
                    )
                    enabledDictionaryIDs.formUnion(installedRecords.map(\.id))
                    try rebuildDictionaryCollection()
                    finishOnboarding()
                }

                importProgressFraction = 1
                importProgressText = failures.isEmpty
                    ? "Import complete"
                    : "Import finished with warnings"
                importProgressDetail = "\(installedRecords.count) of \(sourceCount) imported"
                status = importStatus(
                    installedRecords: installedRecords,
                    failures: failures,
                    sourceCount: sourceCount
                )
            } catch is CancellationError {
                await refreshLibraryAfterCancelledImport(
                    initiallyInstalledIDs: initiallyInstalledIDs,
                    sourceCount: sourceCount
                )
            } catch {
                importProgressText = nil
                importProgressDetail = nil
                importProgressFraction = nil
                status = "Could not refresh the dictionary library: \(error.localizedDescription)"
                TsubameLogging.dictionaryLibrary.error(
                    "Dictionary library refresh failed after import error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func cancelDictionaryImport() {
        guard isImportingDictionary,
              !isCancellingDictionaryImport,
              let importTask else { return }
        isCancellingDictionaryImport = true
        let operation = updatingDictionaryID == nil ? "import" : "update"
        importProgressText = "Cancelling \(operation)…"
        importProgressDetail = "Finishing the current operation and cleaning up…"
        importProgressFraction = nil
        status = "Cancelling dictionary \(operation)…"
        importTask.cancel()
        TsubameLogging.dictionaryLibrary.notice(
            "Dictionary \(operation, privacy: .public) cancellation requested"
        )
    }

    func replaceDictionary(id: UUID, from sourceURL: URL) {
        guard !isDictionaryLibraryBusy,
              let record = installedDictionaries.first(where: { $0.id == id }) else {
            return
        }

        let sessionID = UUID()
        importSessionID = sessionID
        updatingDictionaryID = id
        isImportingDictionary = true
        isCancellingDictionaryImport = false
        importProgressText = sourceURL.lastPathComponent
        importProgressDetail = "Preparing replacement for revision \(record.manifest.revision)"
        importProgressFraction = 0
        status = "Updating \(record.manifest.title)…"

        pipelineTask?.cancel()
        manualLookupTask?.cancel()
        currentRequestID = nil
        popupController.hide()
        dictionary = nil
        entries = []
        matchedRange = nil

        importTask = Task { [weak self] in
            guard let self else { return }
            defer { finishDictionaryImport(sessionID: sessionID) }

            await DictionaryContentService.shared.invalidate()
            await DictionaryImageLoader.shared.invalidate()

            let progress: DictionaryImportProgressHandler = { [weak self] event in
                Task { @MainActor in
                    guard let self,
                          self.importSessionID == sessionID,
                          !self.isCancellingDictionaryImport else { return }
                    self.applyImportProgress(
                        event,
                        sourceName: sourceURL.lastPathComponent,
                        sourceIndex: 1,
                        sourceCount: 1
                    )
                }
            }

            do {
                let replacement = try await replaceDictionaryFile(
                    id: id,
                    sourceURL: sourceURL,
                    progress: progress
                )
                let records = installedDictionaries.map {
                    $0.id == id ? replacement : $0
                }
                applyInstalledDictionaries(records)
                try rebuildDictionaryCollection()
                importProgressFraction = 1
                importProgressText = "Update complete"
                importProgressDetail = "Revision \(record.manifest.revision) → \(replacement.manifest.revision)"
                status = "Updated \(record.manifest.title) from revision \(record.manifest.revision) to \(replacement.manifest.revision)."
                TsubameLogging.dictionaryLibrary.notice(
                    "Dictionary updated id=\(id.uuidString, privacy: .public) oldRevision=\(record.manifest.revision, privacy: .public) newRevision=\(replacement.manifest.revision, privacy: .public)"
                )
            } catch is CancellationError {
                do {
                    try rebuildDictionaryCollection()
                    importProgressText = "Update cancelled"
                    importProgressDetail = "Revision \(record.manifest.revision) remains installed"
                    importProgressFraction = nil
                    status = "Update cancelled. \(record.manifest.title) remains at revision \(record.manifest.revision)."
                } catch {
                    status = "Update was cancelled, but the dictionary could not be reopened: \(error.localizedDescription)"
                }
            } catch {
                do {
                    try rebuildDictionaryCollection()
                } catch {
                    TsubameLogging.dictionaryLibrary.error(
                        "Dictionary reopen failed after update error=\(error.localizedDescription, privacy: .public)"
                    )
                }
                importProgressText = "Update failed"
                importProgressDetail = error.localizedDescription
                importProgressFraction = nil
                status = "Could not update \(record.manifest.title): \(error.localizedDescription)"
                TsubameLogging.dictionaryLibrary.error(
                    "Dictionary update failed id=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func openDictionariesFolder() {
        let folderURL = libraryService.layout.dictionariesRootURL
        do {
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true
            )
            guard NSWorkspace.shared.open(folderURL) else {
                status = "Could not open the dictionaries folder."
                return
            }
            status = "Opened the dictionaries folder in Finder."
        } catch {
            status = "Could not open the dictionaries folder: \(error.localizedDescription)"
            TsubameLogging.dictionaryLibrary.error(
                "Dictionaries folder open failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func toggleDictionary(id: UUID) {
        guard !isDictionaryLibraryBusy else { return }
        guard installedDictionaries.contains(where: { $0.id == id }) else { return }
        let wasEnabled = enabledDictionaryIDs.contains(id)
        if wasEnabled {
            enabledDictionaryIDs.remove(id)
        } else {
            enabledDictionaryIDs.insert(id)
        }
        do {
            try rebuildDictionaryCollection()
        } catch {
            if wasEnabled { enabledDictionaryIDs.insert(id) }
            else { enabledDictionaryIDs.remove(id) }
            status = "Could not open dictionary: \(error.localizedDescription)"
            TsubameLogging.lifecycle.error(
                "Dictionary open failed id=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func moveDictionary(id: UUID, offset: Int) {
        guard !isDictionaryLibraryBusy else { return }
        let previousOrder = dictionaryOrderIDs
        let movedOrder = DictionaryOrder.moving(previousOrder, id: id, offset: offset)
        guard movedOrder != previousOrder else { return }

        dictionaryOrderIDs = movedOrder
        sortInstalledDictionariesByPriority()
        preferences.dictionaryOrderIDs = movedOrder
        do {
            try rebuildDictionaryCollection()
        } catch {
            dictionaryOrderIDs = previousOrder
            sortInstalledDictionariesByPriority()
            preferences.dictionaryOrderIDs = previousOrder
            status = "Could not update dictionary priority: \(error.localizedDescription)"
            TsubameLogging.lifecycle.error(
                "Dictionary priority update failed id=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func removeDictionary(id: UUID) {
        guard !isDictionaryLibraryBusy,
              let record = installedDictionaries.first(where: { $0.id == id }) else {
            return
        }

        removingDictionaryID = id
        pipelineTask?.cancel()
        manualLookupTask?.cancel()
        currentRequestID = nil
        popupController.hide()
        dictionary = nil
        entries = []
        matchedRange = nil
        status = "Moving \(record.manifest.title) to Trash…"

        Task { [weak self] in
            guard let self else { return }
            defer { removingDictionaryID = nil }

            await DictionaryContentService.shared.invalidate()
            await DictionaryImageLoader.shared.invalidate()

            do {
                try await libraryService.remove(dictionaryID: id)
                enabledDictionaryIDs.remove(id)
                dictionaryOrderIDs.removeAll { $0 == id }
                applyInstalledDictionaries(
                    installedDictionaries.filter { $0.id != id }
                )
                try rebuildDictionaryCollection()
                status = installedDictionaries.isEmpty
                    ? "Moved \(record.manifest.title) to Trash. Import a dictionary to continue."
                    : "Moved \(record.manifest.title) to Trash."
                TsubameLogging.dictionaryLibrary.notice(
                    "Dictionary removed id=\(id.uuidString, privacy: .public) title=\(record.manifest.title, privacy: .public)"
                )
            } catch {
                do {
                    try rebuildDictionaryCollection()
                } catch {
                    TsubameLogging.dictionaryLibrary.error(
                        "Dictionary collection reopen failed after removal error=\(error.localizedDescription, privacy: .public)"
                    )
                }
                status = "Could not move \(record.manifest.title) to Trash: \(error.localizedDescription)"
                TsubameLogging.dictionaryLibrary.error(
                    "Dictionary removal failed id=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func rebuildDictionaryCollection() throws {
        pipelineTask?.cancel()
        manualLookupTask?.cancel()
        let enabled = installedDictionaries.filter { enabledDictionaryIDs.contains($0.id) }
        dictionary = enabled.isEmpty ? nil : try DictionaryCollection(records: enabled)
        Task {
            await DictionaryContentService.shared.invalidate()
            await DictionaryImageLoader.shared.invalidate()
        }
        preferences.enabledDictionaryIDs = enabledDictionaryIDs
        entries = []
        matchedRange = nil
        status = enabled.isEmpty
            ? "Enable at least one dictionary."
            : "Ready: \(enabled.count) dictionar\(enabled.count == 1 ? "y" : "ies"). Select text and press \(globalShortcut.displayName)."
        TsubameLogging.lifecycle.notice(
            "Dictionary collection opened enabled=\(enabled.count, privacy: .public) installed=\(self.installedDictionaries.count, privacy: .public)"
        )
    }

    func runManualLookup() {
        guard let dictionary, !query.isEmpty else { return }
        manualLookupTask?.cancel()
        let requestID = makeRequestID()
        let text = query
        status = "Looking up…"

        manualLookupTask = Task { [weak self] in
            do {
                let result = try await dictionary.lookup(
                    text: text,
                    position: 0,
                    requestID: requestID
                )
                try Task.checkCancellation()
                guard let self else { return }
                self.entries = result.entries.map(\.entry)
                self.matchedRange = result.entries.first?.sourceRange
                self.status = result.entries.isEmpty
                    ? "No dictionary matches found."
                    : "Core returned \(result.entries.count) entries."
            } catch is CancellationError {
                TsubameLogging.lookup.debug(
                    "request=\(requestID, privacy: .public) manual lookup cancelled"
                )
            } catch {
                guard let self else { return }
                self.entries = []
                self.matchedRange = nil
                self.status = "Lookup error: \(error.localizedDescription)"
                TsubameLogging.lookup.error(
                    "request=\(requestID, privacy: .public) manual lookup failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func triggerCapture() {
        pipelineTask?.cancel()
        refreshPermissionStatus()
        guard permissionStatus == .granted else {
            TsubameLogging.hotkey.notice("Capture rejected: Accessibility permission denied")
            status = "Accessibility is not effective. On macOS 27, turn Tsubame off and back on in Privacy & Security → Accessibility while Tsubame is running."
            let requestID = makeRequestID()
            currentRequestID = requestID
            popupController.showFeedback(
                .captureFailure(.permissionDenied),
                requestID: requestID
            )
            return
        }
        guard let dictionary else {
            status = "Import a dictionary before using capture."
            TsubameLogging.hotkey.notice("Capture rejected: dictionary is not open")
            onMainWindowRequired?()
            return
        }

        let requestID = makeRequestID()
        currentRequestID = requestID
        status = "Capturing selection…"
        TsubameLogging.hotkey.notice(
            "request=\(requestID, privacy: .public) hotkey pipeline started"
        )

        pipelineTask = Task { [weak self] in
            await self?.runCapturePipeline(
                requestID: requestID,
                dictionary: dictionary
            )
        }
    }

    private func runCapturePipeline(
        requestID: UInt64,
        dictionary: DictionaryCollection
    ) async {
        let clock = ContinuousClock()
        let totalStart = clock.now
        let signpostID = TsubameLogging.signposter.makeSignpostID()
        let totalInterval = TsubameLogging.signposter.beginInterval(
            "Pipeline",
            id: signpostID
        )
        defer {
            TsubameLogging.signposter.endInterval("Pipeline", totalInterval)
        }

        do {
            let coordinator = CaptureLookupCoordinator(
                captureProvider: captureProvider,
                dictionary: dictionary
            )
            let outcome = try await coordinator.execute(requestID: requestID)
            try Task.checkCancellation()
            guard currentRequestID == requestID else { throw CancellationError() }

            let selectedText = outcome.snapshot.selectedRange.substring(
                in: outcome.snapshot.text
            ) ?? outcome.snapshot.text
            let scanPresentation = DictionaryScanPresentation(result: outcome.result)
            entries = outcome.result.entries.map(\.entry)
            matchedRange = scanPresentation.sections.first?.group.sourceRange
            status = scanPresentation.isEmpty
                ? "Captured selection; no dictionary matches found."
                : "Captured from \(outcome.snapshot.sourceApplication.localizedName ?? "another app"); found \(scanPresentation.sections.count) word\(scanPresentation.sections.count == 1 ? "" : "s") and \(scanPresentation.entryCount) entries."

            let initialPresentation = PopupPresentation(
                requestID: requestID,
                selectedText: selectedText,
                contextText: outcome.snapshot.text,
                sourceApplication: outcome.snapshot.sourceApplication,
                result: outcome.result,
                timings: nil,
                showsPerformanceMetrics: developerModeEnabled
            )
            let presentDuration = await popupController.show(
                initialPresentation,
                anchorRectangle: outcome.snapshot.anchorRectangle,
                anchorCoordinateSpace: outcome.snapshot.anchorCoordinateSpace
            )
            try Task.checkCancellation()
            guard currentRequestID == requestID else { throw CancellationError() }

            let totalDuration = totalStart.duration(to: clock.now)
            let timings = PipelineTimings(
                capture: outcome.captureDuration,
                lookup: outcome.lookupDuration,
                present: presentDuration,
                total: totalDuration
            )
            popupController.update(timings: timings)
            TsubameLogging.performance.notice(
                "request=\(requestID, privacy: .public) captureMs=\(timings.capture.milliseconds, format: .fixed(precision: 2), privacy: .public) lookupMs=\(timings.lookup.milliseconds, format: .fixed(precision: 2), privacy: .public) presentMs=\(timings.present.milliseconds, format: .fixed(precision: 2), privacy: .public) totalMs=\(timings.total.milliseconds, format: .fixed(precision: 2), privacy: .public)"
            )
        } catch is CancellationError {
            TsubameLogging.performance.debug(
                "request=\(requestID, privacy: .public) pipeline cancelled"
            )
        } catch {
            guard currentRequestID == requestID else { return }
            entries = []
            matchedRange = nil
            status = error.localizedDescription
            if let captureError = error as? CaptureError {
                popupController.showFeedback(
                    .captureFailure(captureError),
                    requestID: requestID
                )
            } else {
                popupController.hide()
            }
            TsubameLogging.capture.error(
                "request=\(requestID, privacy: .public) pipeline failed type=\(String(describing: type(of: error)), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func makeRequestID() -> UInt64 {
        nextRequestID &+= 1
        return nextRequestID
    }

    func loadInstalledDictionaries() {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        TsubameLogging.dictionaryLibrary.debug(
            "Dictionary library load started root=\(self.libraryService.layout.dictionariesRootURL.path, privacy: .private)"
        )
        Task { [weak self] in
            guard let self else { return }
            defer { isLoadingLibrary = false }
            do {
                let startup = try await libraryService.prepareAndLoad()
                let loaded = startup.dictionaries
                reportStartupMaintenance(startup)
                applyInstalledDictionaries(loaded)
                TsubameLogging.dictionaryLibrary.notice(
                    "Dictionary library loaded count=\(loaded.count, privacy: .public)"
                )
                guard !loaded.isEmpty else {
                    dictionary = nil
                    enabledDictionaryIDs = []
                    status = "Import a Yomitan dictionary to begin."
                    appendStartupMaintenanceWarning(startup)
                    if onboardingCompleted {
                        onMainWindowRequired?()
                    }
                    return
                }

                let installedIDs = Set(loaded.map(\.id))
                enabledDictionaryIDs = preferences.enabledDictionaryIDs
                    .map { $0.intersection(installedIDs) }
                    ?? installedIDs
                try rebuildDictionaryCollection()
                appendStartupMaintenanceWarning(startup)
            } catch {
                dictionary = nil
                enabledDictionaryIDs = []
                status = "Could not load dictionary library: \(error.localizedDescription)"
                TsubameLogging.dictionaryLibrary.error(
                    "Dictionary library load failed error=\(error.localizedDescription, privacy: .public)"
                )
                onMainWindowRequired?()
            }
        }
    }

    private func reportStartupMaintenance(_ startup: DictionaryLibraryStartupResult) {
        let cleanup = startup.cleanupReport
        let recovery = startup.recoveryReport
        if cleanup.removedCount > 0 {
            TsubameLogging.dictionaryLibrary.notice(
                "Removed abandoned dictionary imports count=\(cleanup.removedCount, privacy: .public)"
            )
        }
        if !cleanup.ignoredEntries.isEmpty {
            TsubameLogging.dictionaryLibrary.warning(
                "Preserved unknown dictionary staging entries count=\(cleanup.ignoredEntries.count, privacy: .public)"
            )
        }
        for issue in cleanup.issues {
            TsubameLogging.dictionaryLibrary.error(
                "Dictionary staging cleanup failed path=\(issue.url.path, privacy: .private) error=\(issue.message, privacy: .public)"
            )
        }
        if !recovery.restoredBackups.isEmpty {
            TsubameLogging.dictionaryLibrary.notice(
                "Restored interrupted dictionary replacements count=\(recovery.restoredBackups.count, privacy: .public)"
            )
        }
        if !recovery.removedStaleBackups.isEmpty {
            TsubameLogging.dictionaryLibrary.notice(
                "Removed stale dictionary replacement backups count=\(recovery.removedStaleBackups.count, privacy: .public)"
            )
        }
        if !recovery.ignoredEntries.isEmpty {
            TsubameLogging.dictionaryLibrary.warning(
                "Preserved unknown dictionary replacement entries count=\(recovery.ignoredEntries.count, privacy: .public)"
            )
        }
        for conflict in recovery.conflicts {
            TsubameLogging.dictionaryLibrary.error(
                "Dictionary replacement recovery conflict id=\(conflict.dictionaryID.uuidString, privacy: .public) backups=\(conflict.backupURLs.count, privacy: .public) reason=\(conflict.reason, privacy: .public)"
            )
        }
        for issue in recovery.issues {
            TsubameLogging.dictionaryLibrary.error(
                "Dictionary replacement recovery failed path=\(issue.url.path, privacy: .private) error=\(issue.message, privacy: .public)"
            )
        }
    }

    private func appendStartupMaintenanceWarning(
        _ startup: DictionaryLibraryStartupResult
    ) {
        guard startup.cleanupReport.hasIssues
                || startup.recoveryReport.hasProblems else { return }
        status += " Some interrupted dictionary operations require attention."
    }

    private func applyInstalledDictionaries(
        _ records: [InstalledDictionaryRecord],
        appending newIDs: [UUID] = []
    ) {
        let preferredOrder = dictionaryOrderIDs.isEmpty
            ? preferences.dictionaryOrderIDs ?? []
            : dictionaryOrderIDs
        dictionaryOrderIDs = DictionaryOrder.reconcile(
            preferred: preferredOrder,
            installed: records.map(\.id),
            appending: newIDs
        )
        installedDictionaries = records
        sortInstalledDictionariesByPriority()
        preferences.dictionaryOrderIDs = dictionaryOrderIDs
    }

    private func sortInstalledDictionariesByPriority() {
        var recordsByID: [UUID: InstalledDictionaryRecord] = [:]
        for record in installedDictionaries {
            recordsByID[record.id] = record
        }
        installedDictionaries = dictionaryOrderIDs.compactMap { recordsByID[$0] }
    }

    private func finishDictionaryImport(sessionID: UUID) {
        guard importSessionID == sessionID else { return }
        importTask = nil
        importSessionID = nil
        isImportingDictionary = false
        isCancellingDictionaryImport = false
        updatingDictionaryID = nil
    }

    private func refreshLibraryAfterCancelledImport(
        initiallyInstalledIDs: Set<UUID>,
        sourceCount: Int
    ) async {
        do {
            let loaded = try await libraryService.load()
            let importedIDs = loaded.map(\.id).filter { !initiallyInstalledIDs.contains($0) }
            applyInstalledDictionaries(loaded, appending: importedIDs)
            enabledDictionaryIDs.formUnion(importedIDs)
            try rebuildDictionaryCollection()
            if !importedIDs.isEmpty {
                finishOnboarding()
            }

            importProgressText = "Import cancelled"
            importProgressDetail = "\(importedIDs.count) of \(sourceCount) imported"
            importProgressFraction = nil
            status = importedIDs.isEmpty
                ? "Dictionary import was cancelled."
                : "Import cancelled — \(importedIDs.count) of \(sourceCount) dictionaries imported."
            TsubameLogging.dictionaryLibrary.notice(
                "Dictionary import cancelled completed=\(importedIDs.count, privacy: .public) total=\(sourceCount, privacy: .public)"
            )
        } catch {
            importProgressText = "Import cancelled"
            importProgressDetail = "Could not refresh the dictionary library"
            importProgressFraction = nil
            status = "Import was cancelled, but the dictionary library could not be refreshed: \(error.localizedDescription)"
            TsubameLogging.dictionaryLibrary.error(
                "Dictionary library refresh failed after cancellation error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func installDictionary(
        from sourceURL: URL,
        progress: @escaping DictionaryImportProgressHandler
    ) async throws -> InstalledDictionaryRecord {
        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        TsubameLogging.dictionaryLibrary.notice(
            "Dictionary import started source=\(sourceURL.lastPathComponent, privacy: .public) scopedAccess=\(hasScopedAccess, privacy: .public)"
        )
        return try await libraryService.install(from: sourceURL, progress: progress)
    }

    private func replaceDictionaryFile(
        id: UUID,
        sourceURL: URL,
        progress: @escaping DictionaryImportProgressHandler
    ) async throws -> InstalledDictionaryRecord {
        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        TsubameLogging.dictionaryLibrary.notice(
            "Dictionary update started id=\(id.uuidString, privacy: .public) source=\(sourceURL.lastPathComponent, privacy: .public) scopedAccess=\(hasScopedAccess, privacy: .public)"
        )
        return try await libraryService.replace(
            dictionaryID: id,
            from: sourceURL,
            progress: progress
        )
    }

    private func importStatus(
        installedRecords: [InstalledDictionaryRecord],
        failures: [(source: String, error: String)],
        sourceCount: Int
    ) -> String {
        if failures.isEmpty, let onlyDictionary = installedRecords.first, sourceCount == 1 {
            return "Imported \(onlyDictionary.manifest.title). Select text and press \(globalShortcut.displayName)."
        }
        if failures.isEmpty {
            return "Imported \(installedRecords.count) dictionaries. Select text and press \(globalShortcut.displayName)."
        }
        if installedRecords.isEmpty, let firstFailure = failures.first {
            return sourceCount == 1
                ? "Could not import dictionary: \(firstFailure.error)"
                : "Could not import \(sourceCount) dictionaries. First failure: \(firstFailure.source)."
        }
        return "Imported \(installedRecords.count) of \(sourceCount) dictionaries; \(failures.count) failed."
    }

    private func applyImportProgress(
        _ event: DictionaryImportProgressEvent,
        sourceName: String,
        sourceIndex: Int,
        sourceCount: Int
    ) {
        TsubameLogging.dictionaryLibrary.debug(
            "Dictionary import progress event=\(String(describing: event), privacy: .public)"
        )
        importProgressText = sourceName
        switch event {
        case .phaseStarted(let phase):
            updateImportProgress(
                localFraction: estimatedFraction(for: phase),
                sourceIndex: sourceIndex,
                sourceCount: sourceCount,
                detail: phase.rawValue.capitalized
            )
        case .phaseFinished:
            break
        case .bankStarted(_, let fileName, let index, let total):
            let bankFraction = total > 0 ? Double(index - 1) / Double(total) : 0
            updateImportProgress(
                localFraction: 0.20 + bankFraction * 0.58,
                sourceIndex: sourceIndex,
                sourceCount: sourceCount,
                detail: "Importing \(fileName) (\(index)/\(total))"
            )
        case .bankFinished(_, let fileName, let index, let total, _, _):
            let bankFraction = total > 0 ? Double(index) / Double(total) : 0
            updateImportProgress(
                localFraction: 0.20 + bankFraction * 0.58,
                sourceIndex: sourceIndex,
                sourceCount: sourceCount,
                detail: "Imported \(fileName) (\(index)/\(total))"
            )
        case .completed:
            updateImportProgress(
                localFraction: 1,
                sourceIndex: sourceIndex,
                sourceCount: sourceCount,
                detail: "Finalizing dictionary…"
            )
        }
    }

    private func updateImportProgress(
        localFraction: Double,
        sourceIndex: Int,
        sourceCount: Int,
        detail: String
    ) {
        let overallFraction = (
            Double(sourceIndex - 1) + min(max(localFraction, 0), 1)
        ) / Double(sourceCount)
        importProgressFraction = max(importProgressFraction ?? 0, overallFraction)
        importProgressDetail = importProgressDescription(
            sourceIndex: sourceIndex,
            sourceCount: sourceCount,
            detail: detail
        )
    }

    private func importProgressDescription(
        sourceIndex: Int,
        sourceCount: Int,
        detail: String
    ) -> String {
        sourceCount == 1
            ? detail
            : "Dictionary \(sourceIndex) of \(sourceCount) · \(detail)"
    }

    private func estimatedFraction(for phase: DictionaryImportPhase) -> Double {
        switch phase {
        case .sourcePreparation: 0.02
        case .resourceCopy: 0.08
        case .databaseTransaction: 0.12
        case .databaseSchema: 0.16
        case .databaseIndices: 0.82
        case .databaseIntegrity: 0.88
        case .manifest: 0.92
        case .bundleValidation: 0.95
        case .publication: 0.98
        }
    }
}
