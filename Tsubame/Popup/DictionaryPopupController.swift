import AppKit
import OSLog
import SwiftUI
import TsubameCore

struct PopupPresentation: Sendable {
    let requestID: UInt64
    let selectedText: String
    let contextText: String
    let sourceApplication: SourceApplication
    let result: DictionaryScanResult
    let timings: PipelineTimings?
    let showsPerformanceMetrics: Bool

    func with(timings: PipelineTimings) -> Self {
        Self(
            requestID: requestID,
            selectedText: selectedText,
            contextText: contextText,
            sourceApplication: sourceApplication,
            result: result,
            timings: timings,
            showsPerformanceMetrics: showsPerformanceMetrics
        )
    }

    func with(showsPerformanceMetrics: Bool) -> Self {
        Self(
            requestID: requestID,
            selectedText: selectedText,
            contextText: contextText,
            sourceApplication: sourceApplication,
            result: result,
            timings: timings,
            showsPerformanceMetrics: showsPerformanceMetrics
        )
    }
}

@MainActor
final class DictionaryPopupController {
    private let panel: DictionaryPanel
    private let hostingController: NSHostingController<DictionaryPopupView>
    private let deckModel: DictionaryScanDeckModel
    private var presentation: PopupPresentation?
    private var ankiMiningModel: AnkiMiningModel?
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?

    init() {
        let deckModel = DictionaryScanDeckModel()
        self.deckModel = deckModel
        hostingController = NSHostingController(
            rootView: DictionaryPopupView(
                presentation: nil,
                ankiMiningModel: nil,
                deckModel: deckModel
            )
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

        ankiMiningModel?.beginRequest(presentation.requestID)
        self.presentation = presentation
        deckModel.begin(
            requestID: presentation.requestID,
            scan: DictionaryScanPresentation(result: presentation.result)
        )
        updateRootView()
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
        let scanPresentation = DictionaryScanPresentation(result: presentation.result)
        TsubameLogging.popup.notice(
            "request=\(presentation.requestID, privacy: .public) popup presented words=\(scanPresentation.sections.count, privacy: .public) entries=\(scanPresentation.entryCount, privacy: .public) durationMs=\(duration.milliseconds, format: .fixed(precision: 2), privacy: .public)"
        )
        return duration
    }

    func update(timings: PipelineTimings) {
        guard let presentation else { return }
        let updated = presentation.with(timings: timings)
        self.presentation = updated
        updateRootView()
    }

    func setDeveloperModeEnabled(_ enabled: Bool) {
        guard let presentation else { return }
        let updated = presentation.with(showsPerformanceMetrics: enabled)
        self.presentation = updated
        updateRootView()
    }

    func setAnkiMiningModel(_ model: AnkiMiningModel) {
        ankiMiningModel = model
        updateRootView()
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

    private func updateRootView() {
        hostingController.rootView = DictionaryPopupView(
            presentation: presentation,
            ankiMiningModel: ankiMiningModel,
            deckModel: deckModel
        )
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
    let ankiMiningModel: AnkiMiningModel?
    let deckModel: DictionaryScanDeckModel

    var body: some View {
        Group {
            if let presentation {
                let scanPresentation = DictionaryScanPresentation(
                    result: presentation.result
                )
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "character.book.closed.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(presentation.selectedText)
                                .font(.system(size: 20, weight: .semibold))
                                .lineLimit(2)

                            Text(presentation.sourceApplication.localizedName ?? "Unknown app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !scanPresentation.isEmpty {
                            Text(summary(for: scanPresentation))
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

                    if scanPresentation.isEmpty {
                        ContentUnavailableView(
                            "No dictionary matches",
                            systemImage: "character.book.closed"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PopupScanDeckView(
                            scan: scanPresentation,
                            presentation: presentation,
                            ankiMiningModel: ankiMiningModel,
                            deckModel: deckModel
                        )
                    }

                    if presentation.showsPerformanceMetrics,
                       let timings = presentation.timings {
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

    private func summary(for scan: DictionaryScanPresentation) -> String {
        let wordLabel = scan.sections.count == 1 ? "word" : "words"
        let entryLabel = scan.entryCount == 1 ? "entry" : "entries"
        return "\(scan.sections.count) \(wordLabel) · \(scan.entryCount) \(entryLabel)"
    }
}

private struct PopupScanDeckView: View {
    let scan: DictionaryScanPresentation
    let presentation: PopupPresentation
    let ankiMiningModel: AnkiMiningModel?
    let deckModel: DictionaryScanDeckModel

    private var selectedIndex: Int {
        deckModel.selectedIndex(in: scan) ?? 0
    }

    private var selectedSection: DictionaryScanSection? {
        guard scan.sections.indices.contains(selectedIndex) else { return nil }
        return scan.sections[selectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if scan.sections.count > 1 {
                PopupWordStrip(
                    sections: scan.sections,
                    selectedSectionID: deckModel.selectedSectionID,
                    contextText: presentation.contextText,
                    select: { deckModel.select($0, in: scan) }
                )
                Divider().opacity(0.55)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(.quaternary.opacity(0.22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(.white.opacity(0.06), lineWidth: 1)
                    }
                    .offset(x: -9, y: 6)
                    .rotationEffect(.degrees(-0.65))

                RoundedRectangle(cornerRadius: 13)
                    .fill(.quaternary.opacity(0.3))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }
                    .offset(x: 9, y: 6)
                    .rotationEffect(.degrees(0.65))

                if let selectedSection {
                    PopupActiveScanCard(
                        section: selectedSection,
                        sectionIndex: selectedIndex,
                        sectionCount: scan.sections.count,
                        presentation: presentation,
                        ankiMiningModel: ankiMiningModel,
                        previous: { deckModel.move(by: -1, in: scan) },
                        next: { deckModel.move(by: 1, in: scan) }
                    )
                    .id(selectedSection.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
            }
            .animation(.easeInOut(duration: 0.16), value: deckModel.selectedSectionID)
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PopupWordStrip: View {
    let sections: [DictionaryScanSection]
    let selectedSectionID: UTF8TextRange?
    let contextText: String
    let select: (UTF8TextRange) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(sections) { section in
                        let isSelected = section.id == selectedSectionID
                        Button {
                            select(section.id)
                        } label: {
                            Text(matchedText(for: section))
                                .font(.callout.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    isSelected
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(
                                            isSelected ? Color.accentColor.opacity(0.55) : .clear,
                                            lineWidth: 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .id(section.id)
                        .accessibilityLabel("Show definitions for \(matchedText(for: section))")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selectedSectionID) { _, sectionID in
                guard let sectionID else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    proxy.scrollTo(sectionID, anchor: .center)
                }
            }
        }
    }

    private func matchedText(for section: DictionaryScanSection) -> String {
        section.group.sourceRange.substring(in: contextText)
            ?? section.group.entries.first?.entry.expression
            ?? "Match"
    }
}

private struct PopupActiveScanCard: View {
    let section: DictionaryScanSection
    let sectionIndex: Int
    let sectionCount: Int
    let presentation: PopupPresentation
    let ankiMiningModel: AnkiMiningModel?
    let previous: () -> Void
    let next: () -> Void

    private var matchedText: String {
        section.group.sourceRange.substring(in: presentation.contextText)
            ?? section.group.entries.first?.entry.expression
            ?? "Match"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(matchedText)
                            .font(.system(size: 19, weight: .semibold))
                            .textSelection(.enabled)
                        if let reading {
                            Text(reading)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Word \(sectionIndex + 1) of \(sectionCount) · \(entryCountLabel(section.group.entries.count))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    deckButton(
                        systemName: "chevron.left",
                        help: "Previous word",
                        disabled: sectionIndex == 0,
                        action: previous
                    )
                    deckButton(
                        systemName: "chevron.right",
                        help: "Next word",
                        disabled: sectionIndex == sectionCount - 1,
                        action: next
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider().opacity(0.45)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !section.alternatives.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(section.alternatives) { alternative in
                                    PopupAlternativeGroupView(
                                        group: alternative,
                                        presentation: presentation,
                                        ankiMiningModel: ankiMiningModel
                                    )
                                }
                            }
                            .padding(.top, 10)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Alternative matches (\(section.alternatives.count))")
                                    .font(.caption.weight(.semibold))
                                Text(alternativeSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                        }

                        Divider().opacity(0.35)
                    }

                    PopupEntriesView(
                        entries: section.group.entries,
                        presentation: presentation,
                        ankiMiningModel: ankiMiningModel
                    )
                }
                .padding(14)
            }
            .scrollIndicators(.automatic)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(.white.opacity(0.11), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var reading: String? {
        guard let value = section.group.entries.first?.entry.reading,
              !value.isEmpty,
              value != matchedText else { return nil }
        return value
    }

    private var alternativeSummary: String {
        let matches = section.alternatives.prefix(4).map {
            $0.sourceRange.substring(in: presentation.contextText)
                ?? $0.entries.first?.entry.expression
                ?? "Match"
        }
        let suffix = section.alternatives.count > matches.count ? " · …" : ""
        return matches.joined(separator: " · ") + suffix
    }

    private func entryCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "entry" : "entries")"
    }

    private func deckButton(
        systemName: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }
}

private struct PopupAlternativeGroupView: View {
    let group: DictionaryScanGroup
    let presentation: PopupPresentation
    let ankiMiningModel: AnkiMiningModel?

    private var matchedText: String {
        group.sourceRange.substring(in: presentation.contextText)
            ?? group.entries.first?.entry.expression
            ?? "Match"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(matchedText)
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
            PopupEntriesView(
                entries: group.entries,
                presentation: presentation,
                ankiMiningModel: ankiMiningModel
            )
        }
    }
}

private struct PopupEntriesView: View {
    let entries: [DictionaryLookupEntry]
    let presentation: PopupPresentation
    let ankiMiningModel: AnkiMiningModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(entries) { entry in
                PopupEntryView(
                    entry: entry,
                    presentation: presentation,
                    ankiMiningModel: ankiMiningModel
                )
                if entry.id != entries.last?.id {
                    Divider().opacity(0.35)
                }
            }
        }
    }
}

private struct PopupEntryView: View {
    let entry: DictionaryLookupEntry
    let presentation: PopupPresentation
    let ankiMiningModel: AnkiMiningModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.entry.expression)
                    .font(.system(size: 17, weight: .semibold))
                if !entry.entry.reading.isEmpty,
                   entry.entry.reading != entry.entry.expression {
                    Text(entry.entry.reading)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.dictionaryTitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let ankiMiningModel, ankiMiningModel.isEnabled {
                    AnkiMineButton(
                        model: ankiMiningModel,
                        entry: entry,
                        presentation: presentation
                    )
                }
            }

            ForEach(entry.entry.definitions.prefix(4), id: \.position) { definition in
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

private struct AnkiMineButton: View {
    @Bindable var model: AnkiMiningModel
    let entry: DictionaryLookupEntry
    let presentation: PopupPresentation

    private var state: AnkiMiningState {
        model.state(
            requestID: presentation.requestID,
            dictionaryID: entry.dictionaryID,
            entryID: entry.entry.id,
            sourceRange: entry.sourceRange
        )
    }

    var body: some View {
        Group {
            switch state {
            case .adding:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
                    .help("Adding to Anki…")
            case .added(let noteID):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(width: 24, height: 24)
                    .help("Added to Anki as note \(noteID)")
            case .duplicate:
                Image(systemName: "rectangle.on.rectangle.slash")
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
                    .help("Anki rejected this note as a duplicate")
            case .failed(let message):
                Button(action: mine) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("\(message) Click to retry.")
            case .idle:
                Button(action: mine) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.plain)
                .help("Add this entry to Anki")
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: "Add to Anki"
        case .adding: "Adding to Anki"
        case .added: "Added to Anki"
        case .duplicate: "Duplicate Anki note"
        case .failed: "Anki error; retry"
        }
    }

    private func mine() {
        model.mine(
            requestID: presentation.requestID,
            dictionaryID: entry.dictionaryID,
            entry: entry.entry,
            selectedText: presentation.selectedText,
            contextText: presentation.contextText,
            matchedRange: entry.sourceRange,
            dictionaryTitle: entry.dictionaryTitle,
            sourceApplication: presentation.sourceApplication.localizedName ?? "Unknown app"
        )
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension UTF8TextRange {
    func substring(in text: String) -> String? {
        guard start >= 0, end >= start, end <= text.utf8.count else { return nil }
        let lowerUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: start)
        let upperUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: end)
        guard let lower = String.Index(lowerUTF8, within: text),
              let upper = String.Index(upperUTF8, within: text) else {
            return nil
        }
        return String(text[lower..<upper])
    }
}
