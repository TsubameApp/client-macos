import AppKit
@preconcurrency import ApplicationServices
import Foundation
import OSLog

final class AccessibilityCaptureProvider: CaptureProvider, @unchecked Sendable {
    private struct Selection {
        let context: CaptureTextContext
        let bounds: CGRect?
        let coordinateSpace: CaptureAnchorCoordinateSpace
    }

    private struct SelectionProbe {
        let selection: Selection?
        let exposesSelectionAttributes: Bool
        let encounteredTimeout: Bool
    }

    private struct SelectionSearchResult {
        let selection: Selection?
        let exposesSelectionAttributes: Bool
        let encounteredTimeout: Bool
        let completedTraversal: Bool
    }

    private struct AttributeProbe {
        let value: CFTypeRef?
        let isSupported: Bool
        let timedOut: Bool
    }

    private struct RawCapture: Sendable {
        let text: String
        let selectedRange: CaptureTextRange
        let contextSource: CaptureContextSource
        let anchorRectangle: CGRect?
        let anchorCoordinateSpace: CaptureAnchorCoordinateSpace
    }

    private let queue = DispatchQueue(label: "com.krnya.Tsubame.capture.accessibility")
    private let messagingTimeout: Float

    init(messagingTimeout: Float = 0.35) {
        self.messagingTimeout = messagingTimeout
    }

    func capture(requestID: UInt64) async throws -> CaptureSnapshot {
        let signpostID = TsubameLogging.signposter.makeSignpostID()
        let interval = TsubameLogging.signposter.beginInterval(
            "Capture",
            id: signpostID
        )
        defer {
            TsubameLogging.signposter.endInterval("Capture", interval)
        }

        TsubameLogging.capture.debug(
            "request=\(requestID, privacy: .public) AX capture started"
        )

        guard let sourceApplication = await MainActor.run(body: {
            guard let application = NSWorkspace.shared.frontmostApplication else {
                return nil as SourceApplication?
            }
            return SourceApplication(
                processIdentifier: Int32(application.processIdentifier),
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName
            )
        }) else {
            throw CaptureError.noFocusedApplication
        }
        TsubameLogging.capture.notice(
            "request=\(requestID, privacy: .public) targetPID=\(sourceApplication.processIdentifier, privacy: .public) target=\(sourceApplication.bundleIdentifier ?? "unknown", privacy: .public)"
        )

        let raw = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(
                        returning: try captureSynchronously(
                            processIdentifier: pid_t(sourceApplication.processIdentifier),
                            requestID: requestID
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()

        let snapshot = try CaptureSnapshot(
            text: raw.text,
            selectedRange: raw.selectedRange,
            anchorRectangle: raw.anchorRectangle,
            anchorCoordinateSpace: raw.anchorCoordinateSpace,
            sourceApplication: sourceApplication,
            method: .accessibility,
            contextSource: raw.contextSource
        )

        TsubameLogging.capture.notice(
            "request=\(requestID, privacy: .public) captured contextBytes=\(snapshot.text.utf8.count, privacy: .public) selectedBytes=\(snapshot.selectedRange.end - snapshot.selectedRange.start, privacy: .public) contextSource=\(snapshot.contextSource.rawValue, privacy: .public) source=\(sourceApplication.bundleIdentifier ?? "unknown", privacy: .public) method=\(snapshot.method.rawValue, privacy: .public) hasBounds=\(snapshot.anchorRectangle != nil, privacy: .public)"
        )
        TsubameLogging.logCapturedText(
            raw.selectedRange.substring(in: raw.text) ?? raw.text,
            requestID: requestID
        )
        return snapshot
    }

    private func captureSynchronously(
        processIdentifier: pid_t,
        requestID: UInt64
    ) throws -> RawCapture {
        guard AXIsProcessTrusted() else { throw CaptureError.permissionDenied }

        let application = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, messagingTimeout)
        let roleProbeSucceeded = try optionalAttributeValue(
            kAXRoleAttribute as CFString,
            from: application
        ) != nil

        let initialSearch = try findSelection(
            in: captureRoots(
                application: application,
                processIdentifier: processIdentifier
            )
        )
        var exposesSelectionAttributes = initialSearch.exposesSelectionAttributes
        var encounteredTimeout = initialSearch.encounteredTimeout
        var completedTraversal = initialSearch.completedTraversal
        if let selection = initialSearch.selection {
            return RawCapture(
                text: selection.context.text,
                selectedRange: selection.context.selectedRange,
                contextSource: selection.context.source,
                anchorRectangle: selection.bounds,
                anchorCoordinateSpace: selection.coordinateSpace
            )
        }

        // Chromium publishes its web accessibility tree after an assistive
        // client probes AXRole. Give the renderer one bounded retry to expose it.
        if roleProbeSucceeded {
            TsubameLogging.capture.debug(
                "request=\(requestID, privacy: .public) AXRole probe completed; retrying web accessibility tree"
            )
            Thread.sleep(forTimeInterval: 0.08)
            let retrySearch = try findSelection(
                in: captureRoots(
                    application: application,
                    processIdentifier: processIdentifier
                )
            )
            exposesSelectionAttributes = exposesSelectionAttributes
                || retrySearch.exposesSelectionAttributes
            encounteredTimeout = encounteredTimeout
                || retrySearch.encounteredTimeout
            completedTraversal = completedTraversal
                && retrySearch.completedTraversal
            if let selection = retrySearch.selection {
                return RawCapture(
                    text: selection.context.text,
                    selectedRange: selection.context.selectedRange,
                    contextSource: selection.context.source,
                    anchorRectangle: selection.bounds,
                    anchorCoordinateSpace: selection.coordinateSpace
                )
            }
        }

        throw AccessibilityCaptureClassification.missingSelectionError(
            exposesSelectionAttributes: exposesSelectionAttributes,
            completedTraversal: completedTraversal,
            encounteredTimeout: encounteredTimeout
        )
    }

    private func captureRoots(
        application: AXUIElement,
        processIdentifier: pid_t
    ) throws -> [AXUIElement] {
        var roots: [AXUIElement] = []
        let systemWide = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        if let focused = try optionalElementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: systemWide
        ), pid(of: focused) == processIdentifier {
            roots.append(focused)
        }
        if let focused = try optionalElementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: application
        ) {
            roots.append(focused)
        }
        if let window = try optionalElementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: application
        ) {
            roots.append(window)
        }
        roots.append(application)
        return roots
    }

    private func findSelection(
        in roots: [AXUIElement],
        maximumElements: Int = 400
    ) throws -> SelectionSearchResult {
        var pending = roots
        var nextIndex = 0
        var visited: Set<CFHashCode> = []
        var exposesSelectionAttributes = false
        var encounteredTimeout = false

        while nextIndex < pending.count, visited.count < maximumElements {
            let element = pending[nextIndex]
            nextIndex += 1
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }
            _ = AXUIElementSetMessagingTimeout(element, messagingTimeout)
            _ = try optionalAttributeValue(
                kAXRoleAttribute as CFString,
                from: element
            )

            let probe = try selection(from: element)
            exposesSelectionAttributes = exposesSelectionAttributes
                || probe.exposesSelectionAttributes
            encounteredTimeout = encounteredTimeout || probe.encounteredTimeout
            if let selection = probe.selection {
                return SelectionSearchResult(
                    selection: selection,
                    exposesSelectionAttributes: true,
                    encounteredTimeout: encounteredTimeout,
                    completedTraversal: false
                )
            }
            pending.append(contentsOf: try children(of: element))
        }
        return SelectionSearchResult(
            selection: nil,
            exposesSelectionAttributes: exposesSelectionAttributes,
            encounteredTimeout: encounteredTimeout,
            completedTraversal: nextIndex >= pending.count
        )
    }

    private func selection(
        from element: AXUIElement
    ) throws -> SelectionProbe {
        let markerRange = try probeSelectionAttribute(
            kAXSelectedTextMarkerRangeAttribute as CFString,
            from: element
        )
        if let value = markerRange.value {
            guard CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else {
                throw CaptureError.invalidAccessibilityValue
            }
            if let selection = try markerSelection(
                markerRange: value,
                from: element
            ) {
                return SelectionProbe(
                    selection: selection,
                    exposesSelectionAttributes: true,
                    encounteredTimeout: markerRange.timedOut
                )
            }
        }

        let selectedText = try probeSelectionAttribute(
            kAXSelectedTextAttribute as CFString,
            from: element
        )
        if let value = selectedText.value {
            guard CFGetTypeID(value) == CFStringGetTypeID() else {
                throw CaptureError.invalidAccessibilityValue
            }
            let text = value as! String
            if !text.isEmpty {
                let range = try optionalRangeAttribute(
                    kAXSelectedTextRangeAttribute as CFString,
                    from: element
                )
                let fullText = try optionalStringAttribute(
                    kAXValueAttribute as CFString,
                    from: element
                )
                let context = CaptureTextContext.resolve(
                    selectedText: text,
                    fullText: fullText,
                    selectedUTF16Range: range.map {
                        NSRange(location: $0.location, length: $0.length)
                    }
                )
                return SelectionProbe(
                    selection: Selection(
                        context: context,
                        bounds: range.flatMap { bounds(for: $0, in: element) },
                        coordinateSpace: .accessibilityTopLeft
                    ),
                    exposesSelectionAttributes: true,
                    encounteredTimeout: markerRange.timedOut || selectedText.timedOut
                )
            }
        }

        return SelectionProbe(
            selection: nil,
            exposesSelectionAttributes: markerRange.isSupported || selectedText.isSupported,
            encounteredTimeout: markerRange.timedOut || selectedText.timedOut
        )
    }

    private func markerSelection(
        markerRange: CFTypeRef,
        from element: AXUIElement
    ) throws -> Selection? {
        guard let textValue = try optionalParameterizedAttributeValue(
                kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
                parameter: markerRange,
                from: element
              ) else {
            return nil
        }
        guard CFGetTypeID(textValue) == CFStringGetTypeID() else {
            throw CaptureError.invalidAccessibilityValue
        }

        let text = textValue as! String
        guard !text.isEmpty else { return nil }
        let sentenceText = try sentenceText(
            containing: markerRange,
            in: element
        )
        let context = CaptureTextContext.resolve(
            selectedText: text,
            fullText: sentenceText,
            selectedUTF16Range: nil,
            fullTextSource: .sentenceTextMarker
        )
        let markerBounds = try optionalParameterizedAttributeValue(
            kAXBoundsForTextMarkerRangeParameterizedAttribute as CFString,
            parameter: markerRange,
            from: element
        ).flatMap(rectangle(from:))
        // Chromium returns AXBoundsForTextMarkerRange as an NSRect already in
        // AppKit screen coordinates, unlike the regular AX range bounds.
        return Selection(
            context: context,
            bounds: markerBounds,
            coordinateSpace: .appKitBottomLeft
        )
    }

    private func sentenceText(
        containing markerRangeValue: CFTypeRef,
        in element: AXUIElement
    ) throws -> String? {
        let markerRange = unsafeDowncast(
            markerRangeValue,
            to: AXTextMarkerRange.self
        )
        let startMarker = AXTextMarkerRangeCopyStartMarker(markerRange)
        guard let sentenceRange = try optionalParameterizedAttributeValue(
            kAXSentenceTextMarkerRangeForTextMarkerParameterizedAttribute as CFString,
            parameter: startMarker,
            from: element
        ), CFGetTypeID(sentenceRange) == AXTextMarkerRangeGetTypeID(),
              let value = try optionalParameterizedAttributeValue(
                kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
                parameter: sentenceRange,
                from: element
              ), CFGetTypeID(value) == CFStringGetTypeID()
        else {
            return nil
        }
        return value as? String
    }

    private func optionalStringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) throws -> String? {
        guard let value = try optionalAttributeValue(attribute, from: element),
              CFGetTypeID(value) == CFStringGetTypeID()
        else {
            return nil
        }
        return value as? String
    }

    private func optionalElementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) throws -> AXUIElement? {
        guard let value = try optionalAttributeValue(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func optionalRangeAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) throws -> CFRange? {
        guard let value = try optionalAttributeValue(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func children(of element: AXUIElement) throws -> [AXUIElement] {
        guard let value = try optionalAttributeValue(
            kAXChildrenAttribute as CFString,
            from: element
        ), CFGetTypeID(value) == CFArrayGetTypeID()
        else {
            return []
        }
        let array = unsafeDowncast(value, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else {
                return nil
            }
            let child = Unmanaged<AXUIElement>
                .fromOpaque(pointer)
                .takeUnretainedValue()
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
            return child
        }
    }

    private func pid(of element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }

    private func bounds(for range: CFRange, in element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let parameter = AXValueCreate(.cfRange, &mutableRange) else { return nil }

        var rawValue: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter,
            &rawValue
        )
        guard error == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = unsafeDowncast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rectangle = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rectangle) else { return nil }
        return rectangle
    }

    private func optionalAttributeValue(
        _ attribute: CFString,
        from element: AXUIElement
    ) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        switch error {
        case .success:
            return value
        case .apiDisabled:
            throw CaptureError.permissionDenied
        case .cannotComplete:
            return nil
        case .attributeUnsupported, .notImplemented, .noValue,
             .invalidUIElement, .illegalArgument:
            return nil
        default:
            return nil
        }
    }

    private func probeSelectionAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) throws -> AttributeProbe {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        switch error {
        case .success:
            return AttributeProbe(value: value, isSupported: true, timedOut: false)
        case .noValue:
            return AttributeProbe(value: nil, isSupported: true, timedOut: false)
        case .cannotComplete:
            return AttributeProbe(value: nil, isSupported: false, timedOut: true)
        case .apiDisabled:
            throw CaptureError.permissionDenied
        case .attributeUnsupported, .notImplemented, .invalidUIElement,
             .illegalArgument:
            return AttributeProbe(value: nil, isSupported: false, timedOut: false)
        default:
            throw CaptureError.invalidAccessibilityValue
        }
    }

    private func optionalParameterizedAttributeValue(
        _ attribute: CFString,
        parameter: CFTypeRef,
        from element: AXUIElement
    ) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute,
            parameter,
            &value
        )
        switch error {
        case .success:
            return value
        case .apiDisabled:
            throw CaptureError.permissionDenied
        default:
            return nil
        }
    }

    private func rectangle(from value: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rectangle = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rectangle) else { return nil }
        return rectangle
    }
}

enum AccessibilityCaptureClassification {
    static func missingSelectionError(
        exposesSelectionAttributes: Bool,
        completedTraversal: Bool,
        encounteredTimeout: Bool
    ) -> CaptureError {
        if exposesSelectionAttributes {
            return .noSelection
        }
        if encounteredTimeout {
            return .accessibilityTimedOut
        }
        return completedTraversal
            ? .unsupportedApplication
            : .invalidAccessibilityValue
    }
}
