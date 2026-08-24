import AppKit
import Foundation
import Observation
import OSLog
import TsubameCore

@MainActor
@Observable
final class AppModel {
    var query = "食べました"
    private(set) var databaseURL: URL?
    private(set) var entries: [DictionaryEntry] = []
    private(set) var matchedRange: UTF8TextRange?
    private(set) var status = "Choose an imported dictionary.sqlite to begin."
    private(set) var permissionStatus: AccessibilityPermissionStatus

    @ObservationIgnored private let captureProvider: any CaptureProvider
    @ObservationIgnored private let permissionClient: AccessibilityPermissionClient
    @ObservationIgnored private let popupController: DictionaryPopupController
    @ObservationIgnored private let hotKeyMonitor: GlobalHotKeyMonitor
    @ObservationIgnored private var dictionary: DictionaryEngine?
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    @ObservationIgnored private var manualLookupTask: Task<Void, Never>?
    @ObservationIgnored private var nextRequestID: UInt64 = 0
    @ObservationIgnored private var currentRequestID: UInt64?
    @ObservationIgnored private var hasStarted = false

    init(
        captureProvider: any CaptureProvider = AccessibilityCaptureProvider(),
        permissionClient: AccessibilityPermissionClient = .init(),
        popupController: DictionaryPopupController = .init(),
        hotKeyMonitor: GlobalHotKeyMonitor = .init()
    ) {
        self.captureProvider = captureProvider
        self.permissionClient = permissionClient
        self.popupController = popupController
        self.hotKeyMonitor = hotKeyMonitor
        permissionStatus = permissionClient.status()
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

    func openDictionary(at url: URL) {
        pipelineTask?.cancel()
        manualLookupTask?.cancel()

        do {
            dictionary = try DictionaryEngine(databaseURL: url)
            databaseURL = url
            entries = []
            matchedRange = nil
            status = "Ready: \(url.deletingLastPathComponent().lastPathComponent). Select text and press \(GlobalHotKeyMonitor.displayName)."
            TsubameLogging.lifecycle.notice(
                "Dictionary opened file=\(url.lastPathComponent, privacy: .public)"
            )
        } catch {
            dictionary = nil
            databaseURL = nil
            entries = []
            matchedRange = nil
            status = "Could not open dictionary: \(error.localizedDescription)"
            TsubameLogging.lifecycle.error(
                "Dictionary open failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
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
                self.entries = result.entries
                self.matchedRange = result.sourceRange
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
            status = "Choose dictionary.sqlite before using capture."
            TsubameLogging.hotkey.notice("Capture rejected: dictionary is not open")
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
        dictionary: DictionaryEngine
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
            entries = outcome.result.entries
            matchedRange = outcome.result.sourceRange
            status = outcome.result.entries.isEmpty
                ? "Captured selection; no dictionary matches found."
                : "Captured from \(outcome.snapshot.sourceApplication.localizedName ?? "another app"); found \(outcome.result.entries.count) entries."

            let initialPresentation = PopupPresentation(
                requestID: requestID,
                selectedText: selectedText,
                sourceApplication: outcome.snapshot.sourceApplication,
                result: outcome.result,
                timings: nil
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
}
