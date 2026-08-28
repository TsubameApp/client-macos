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
    private(set) var isLoadingLibrary = false
    private(set) var isImportingDictionary = false
    private(set) var importProgressText: String?
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

    func importDictionary(from sourceURL: URL) {
        guard !isImportingDictionary else { return }
        isImportingDictionary = true
        importProgressText = "Preparing dictionary…"
        importProgressFraction = nil
        status = "Importing \(sourceURL.lastPathComponent)…"
        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        TsubameLogging.dictionaryLibrary.notice(
            "Dictionary import started source=\(sourceURL.lastPathComponent, privacy: .public) scopedAccess=\(hasScopedAccess, privacy: .public)"
        )

        let progress: DictionaryImportProgressHandler = { [weak self] event in
            Task { @MainActor in
                self?.applyImportProgress(event)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            defer {
                if hasScopedAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                isImportingDictionary = false
            }

            do {
                let installed = try await libraryService.install(
                    from: sourceURL,
                    progress: progress
                )
                installedDictionaries = try await libraryService.load()
                enabledDictionaryIDs.insert(installed.id)
                try rebuildDictionaryCollection()
                importProgressText = "Imported \(installed.manifest.title)"
                importProgressFraction = 1
                status = "Imported \(installed.manifest.title). Select text and press \(GlobalHotKeyMonitor.displayName)."
                TsubameLogging.dictionaryLibrary.notice(
                    "Dictionary installed id=\(installed.id.uuidString, privacy: .public) title=\(installed.manifest.title, privacy: .public)"
                )
                finishOnboarding()
            } catch is CancellationError {
                importProgressText = "Import cancelled."
                importProgressFraction = nil
                status = "Dictionary import was cancelled."
            } catch {
                importProgressText = nil
                importProgressFraction = nil
                status = "Could not import dictionary: \(error.localizedDescription)"
                TsubameLogging.dictionaryLibrary.error(
                    "Dictionary import failed source=\(sourceURL.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
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
                installedDictionaries = loaded
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

    private func applyImportProgress(_ event: DictionaryImportProgressEvent) {
        TsubameLogging.dictionaryLibrary.debug(
            "Dictionary import progress event=\(String(describing: event), privacy: .public)"
        )
        switch event {
        case .phaseStarted(let phase):
            importProgressText = phase.rawValue.capitalized
            importProgressFraction = nil
        case .phaseFinished:
            break
        case .bankStarted(_, let fileName, let index, let total):
            importProgressText = "Importing \(fileName) (\(index)/\(total))"
            importProgressFraction = total > 0 ? Double(index - 1) / Double(total) : nil
        case .bankFinished(_, let fileName, let index, let total, _, _):
            importProgressText = "Imported \(fileName) (\(index)/\(total))"
            importProgressFraction = total > 0 ? Double(index) / Double(total) : nil
        case .completed:
            importProgressText = "Finalizing dictionary…"
            importProgressFraction = 1
        }
    }
}
