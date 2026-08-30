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
    private(set) var importProgressText: String?
    private(set) var importProgressDetail: String?
    private(set) var importProgressFraction: Double?
    private(set) var entries: [DictionaryEntry] = []
    private(set) var matchedRange: UTF8TextRange?
    private(set) var status = "Loading installed dictionaries…"
    private(set) var permissionStatus: AccessibilityPermissionStatus

    var onOnboardingCompleted: (() -> Void)?
    var onMainWindowRequired: (() -> Void)?

    @ObservationIgnored private let captureProvider: any CaptureProvider
    @ObservationIgnored private let permissionClient: AccessibilityPermissionClient
    @ObservationIgnored private let popupController: DictionaryPopupController
    @ObservationIgnored private let hotKeyMonitor: GlobalHotKeyMonitor
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let libraryService: DictionaryLibraryService
    @ObservationIgnored let ankiSettings: AnkiSettingsModel
    @ObservationIgnored private let ankiMining: AnkiMiningModel
    @ObservationIgnored private var dictionary: DictionaryCollection?
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    @ObservationIgnored private var manualLookupTask: Task<Void, Never>?
    @ObservationIgnored private var nextRequestID: UInt64 = 0
    @ObservationIgnored private var currentRequestID: UInt64?
    @ObservationIgnored private var hasStarted = false

    init(
        captureProvider: any CaptureProvider = AccessibilityCaptureProvider(),
        permissionClient: AccessibilityPermissionClient = .init(),
        popupController: DictionaryPopupController = .init(),
        hotKeyMonitor: GlobalHotKeyMonitor = .init(),
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

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshPermissionStatus()
        hotKeyMonitor.start { [weak self] in
            self?.triggerCapture()
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
        guard !isImportingDictionary, !sourceURLs.isEmpty else { return }
        let sourceCount = sourceURLs.count
        isImportingDictionary = true
        importProgressText = sourceCount == 1
            ? sourceURLs[0].lastPathComponent
            : "Preparing dictionaries…"
        importProgressDetail = sourceCount == 1 ? "Starting import" : "0 of \(sourceCount) completed"
        importProgressFraction = 0
        status = sourceCount == 1
            ? "Importing \(sourceURLs[0].lastPathComponent)…"
            : "Importing \(sourceCount) dictionaries…"

        Task { [weak self] in
            guard let self else { return }
            defer { isImportingDictionary = false }

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
                            self?.applyImportProgress(
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
                    let loaded = try await libraryService.load()
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
                importProgressText = "Import cancelled."
                importProgressDetail = nil
                importProgressFraction = nil
                status = "Dictionary import was cancelled."
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

    private func rebuildDictionaryCollection() throws {
        pipelineTask?.cancel()
        manualLookupTask?.cancel()
        let enabled = installedDictionaries.filter { enabledDictionaryIDs.contains($0.id) }
        dictionary = enabled.isEmpty ? nil : try DictionaryCollection(records: enabled)
        preferences.enabledDictionaryIDs = enabledDictionaryIDs
        entries = []
        matchedRange = nil
        status = enabled.isEmpty
            ? "Enable at least one dictionary."
            : "Ready: \(enabled.count) dictionar\(enabled.count == 1 ? "y" : "ies"). Select text and press \(GlobalHotKeyMonitor.displayName)."
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
        refreshPermissionStatus()
        guard permissionStatus == .granted else {
            TsubameLogging.hotkey.notice("Capture rejected: Accessibility permission denied")
            status = "Accessibility is not effective. On macOS 27, turn Tsubame off and back on in Privacy & Security → Accessibility while Tsubame is running."
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let dictionary else {
            status = "Import a dictionary before using capture."
            TsubameLogging.hotkey.notice("Capture rejected: dictionary is not open")
            onMainWindowRequired?()
            return
        }

        pipelineTask?.cancel()
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
            entries = outcome.result.entries.map(\.entry)
            matchedRange = outcome.result.entries.first?.sourceRange
            status = outcome.result.entries.isEmpty
                ? "Captured selection; no dictionary matches found."
                : "Captured from \(outcome.snapshot.sourceApplication.localizedName ?? "another app"); found \(outcome.result.entries.count) entries."

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
            popupController.hide()
            entries = []
            matchedRange = nil
            status = error.localizedDescription
            TsubameLogging.capture.error(
                "request=\(requestID, privacy: .public) pipeline failed type=\(String(describing: type(of: error)), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func makeRequestID() -> UInt64 {
        nextRequestID &+= 1
        return nextRequestID
    }

    private func loadInstalledDictionaries() {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        TsubameLogging.dictionaryLibrary.debug(
            "Dictionary library load started root=\(self.libraryService.layout.dictionariesRootURL.path, privacy: .private)"
        )
        Task { [weak self] in
            guard let self else { return }
            defer { isLoadingLibrary = false }
            do {
                let loaded = try await libraryService.load()
                applyInstalledDictionaries(loaded)
                TsubameLogging.dictionaryLibrary.notice(
                    "Dictionary library loaded count=\(loaded.count, privacy: .public)"
                )
                guard !loaded.isEmpty else {
                    dictionary = nil
                    enabledDictionaryIDs = []
                    status = "Import a Yomitan dictionary to begin."
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

    private func importStatus(
        installedRecords: [InstalledDictionaryRecord],
        failures: [(source: String, error: String)],
        sourceCount: Int
    ) -> String {
        if failures.isEmpty, let onlyDictionary = installedRecords.first, sourceCount == 1 {
            return "Imported \(onlyDictionary.manifest.title). Select text and press \(GlobalHotKeyMonitor.displayName)."
        }
        if failures.isEmpty {
            return "Imported \(installedRecords.count) dictionaries. Select text and press \(GlobalHotKeyMonitor.displayName)."
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
