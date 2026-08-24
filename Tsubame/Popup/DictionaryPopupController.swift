import AppKit
import OSLog
import SwiftUI
import TsubameCore

struct PopupPresentation: Sendable {
    let requestID: UInt64
    let selectedText: String
    let sourceApplication: SourceApplication
    let result: LookupResult
    let timings: PipelineTimings?

    func with(timings: PipelineTimings) -> Self {
        Self(
            requestID: requestID,
            selectedText: selectedText,
            sourceApplication: sourceApplication,
            result: result,
            timings: timings
        )
    }
}

@MainActor
final class DictionaryPopupController {
    private let panel: DictionaryPanel
    private let hostingController: NSHostingController<DictionaryPopupView>
    private var presentation: PopupPresentation?
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?

    init() {
        hostingController = NSHostingController(
            rootView: DictionaryPopupView(presentation: nil)
        )
        panel = DictionaryPanel(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
    }

    func show(
        _ presentation: PopupPresentation,
        anchorRectangle: CGRect?,
        anchorCoordinateSpace: CaptureAnchorCoordinateSpace
    ) async -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        let signpostID = TsubameLogging.signposter.makeSignpostID()
        let interval = TsubameLogging.signposter.beginInterval("Present", id: signpostID)
        defer {
            TsubameLogging.signposter.endInterval("Present", interval)
        }

        self.presentation = presentation
        hostingController.rootView = DictionaryPopupView(presentation: presentation)
        let panelOrigin = origin(
            for: panel.frame.size,
            anchorRectangle: anchorRectangle,
            coordinateSpace: anchorCoordinateSpace
        )
        panel.setFrameOrigin(panelOrigin)
        TsubameLogging.popup.debug(
            "request=\(presentation.requestID, privacy: .public) rawAnchor=\(String(describing: anchorRectangle), privacy: .public) coordinateSpace=\(anchorCoordinateSpace.rawValue, privacy: .public) panelOrigin=\(String(describing: panelOrigin), privacy: .public)"
        )
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        installDismissMonitors()
        await Task.yield()

        let duration = start.duration(to: clock.now)
        TsubameLogging.popup.notice(
            "request=\(presentation.requestID, privacy: .public) popup presented entries=\(presentation.result.entries.count, privacy: .public) durationMs=\(duration.milliseconds, format: .fixed(precision: 2), privacy: .public)"
        )
        return duration
    }

    func update(timings: PipelineTimings) {
        guard let presentation else { return }
        let updated = presentation.with(timings: timings)
        self.presentation = updated
        hostingController.rootView = DictionaryPopupView(presentation: updated)
    }

    func hide() {
        removeDismissMonitors()
        panel.orderOut(nil)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        let eventMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .keyDown
        ]

        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: eventMask
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleDismissEvent(event)
            }
        }
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: eventMask
        ) { [weak self] event in
            guard let self else { return event }
            if handleDismissEvent(event) {
                return nil
            }
            return event
        }
    }

    @discardableResult
    private func handleDismissEvent(_ event: NSEvent) -> Bool {
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return false }
            hide()
            return true
        }

        guard !panel.frame.contains(NSEvent.mouseLocation) else { return false }
        hide()
        return false
    }

    private func removeDismissMonitors() {
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
        }
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
        }
        globalDismissMonitor = nil
        localDismissMonitor = nil
    }

    private func origin(
        for panelSize: CGSize,
        anchorRectangle: CGRect?,
        coordinateSpace: CaptureAnchorCoordinateSpace
    ) -> CGPoint {
        let anchor = anchorRectangle.flatMap { rectangle in
            switch coordinateSpace {
            case .accessibilityTopLeft:
                convertAXRectangleToAppKit(rectangle)
            case .appKitBottomLeft:
                validatedAppKitRectangle(rectangle)
            }
        }
            ?? fallbackAnchor()
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.center) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(
            x: anchor.minX,
            y: anchor.minY,
            width: panelSize.width,
            height: panelSize.height
        )

        var x = anchor.minX
        var y = anchor.minY - panelSize.height - 8
        if y < visibleFrame.minY {
            y = anchor.maxY + 8
        }
        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - panelSize.width)
        y = min(max(y, visibleFrame.minY), visibleFrame.maxY - panelSize.height)
        return CGPoint(x: x, y: y)
    }

    private func convertAXRectangleToAppKit(_ rectangle: CGRect) -> CGRect? {
        guard rectangle.origin.x.isFinite,
              rectangle.origin.y.isFinite,
              rectangle.width.isFinite,
              rectangle.height.isFinite,
              rectangle.width >= 0,
              rectangle.height > 0
        else {
            return nil
        }

        let screenGeometries = NSScreen.screens.compactMap { screen -> (
            screen: NSScreen,
            quartzFrame: CGRect
        )? in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else {
                return nil
            }
            return (screen, CGDisplayBounds(CGDirectDisplayID(number.uint32Value)))
        }
        guard let geometry = screenGeometries.max(by: {
            intersectionArea(rectangle, $0.quartzFrame)
                < intersectionArea(rectangle, $1.quartzFrame)
        }), intersectionArea(rectangle, geometry.quartzFrame) > 0 else {
            return nil
        }

        // A web view may report the union of a long multi-line selection.
        // The pointer is a more useful visual anchor in that case.
        guard rectangle.width <= geometry.quartzFrame.width * 0.75,
              rectangle.height <= geometry.quartzFrame.height * 0.35
        else {
            return nil
        }

        let localX = rectangle.minX - geometry.quartzFrame.minX
        let localTop = rectangle.minY - geometry.quartzFrame.minY
        return CGRect(
            x: geometry.screen.frame.minX + localX,
            y: geometry.screen.frame.maxY - localTop - rectangle.height,
            width: rectangle.width,
            height: rectangle.height
        )
    }

    private func validatedAppKitRectangle(_ rectangle: CGRect) -> CGRect? {
        guard rectangle.origin.x.isFinite,
              rectangle.origin.y.isFinite,
              rectangle.width.isFinite,
              rectangle.height.isFinite,
              rectangle.width >= 0,
              rectangle.height > 0,
              let screen = NSScreen.screens.max(by: {
                intersectionArea(rectangle, $0.frame)
                    < intersectionArea(rectangle, $1.frame)
              }),
              intersectionArea(rectangle, screen.frame) > 0,
              rectangle.width <= screen.frame.width * 0.75,
              rectangle.height <= screen.frame.height * 0.35
        else {
            return nil
        }
        return rectangle
    }

    private func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func fallbackAnchor() -> CGRect {
        let point = NSEvent.mouseLocation
        return CGRect(x: point.x, y: point.y, width: 1, height: 1)
    }
}

private final class DictionaryPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct DictionaryPopupView: View {
    let presentation: PopupPresentation?

    var body: some View {
        Group {
            if let presentation {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "character.book.closed.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(presentation.selectedText)
                                .font(.system(size: 23, weight: .semibold))
                                .lineLimit(1)

                            Text(presentation.sourceApplication.localizedName ?? "Unknown app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !presentation.result.entries.isEmpty {
                            Text("\(presentation.result.entries.count)")
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)

                    Divider().opacity(0.7)

                    if presentation.result.entries.isEmpty {
                        ContentUnavailableView(
                            "No dictionary matches",
                            systemImage: "character.book.closed"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(presentation.result.entries, id: \.id) { entry in
                                    PopupEntryView(entry: entry)
                                    if entry.id != presentation.result.entries.last?.id {
                                        Divider().opacity(0.55)
                                    }
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                        }
                        .scrollIndicators(.automatic)
                    }

#if DEBUG
                    if let timings = presentation.timings {
                        VStack(spacing: 0) {
                            Divider().opacity(0.7)
                            HStack {
                                Image(systemName: "gauge.with.dots.needle.33percent")
                                Text(timings.debugSummary)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                        }
                    }
#endif
                }
            } else {
                Color.clear
            }
        }
        .frame(width: 520, height: 400)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct PopupEntryView: View {
    let entry: DictionaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.expression)
                    .font(.system(size: 17, weight: .semibold))
                if !entry.reading.isEmpty, entry.reading != entry.expression {
                    Text(entry.reading)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(entry.definitions.prefix(4), id: \.position) { definition in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(definition.position + 1).")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Text(definition.text ?? "Structured definition")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
