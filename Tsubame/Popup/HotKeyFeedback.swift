import Foundation

enum HotKeyFeedbackKind: Sendable, Equatable {
    case noSelection
    case unsupportedApplication
    case permissionDenied
    case accessibilityTimedOut
    case accessibilityError
}

struct HotKeyFeedbackPresentation: Sendable, Equatable {
    let kind: HotKeyFeedbackKind
    let title: String
    let message: String
    let symbolName: String

    static func captureFailure(_ error: CaptureError) -> Self {
        switch error {
        case .noSelection:
            Self(
                kind: .noSelection,
                title: "No text selected",
                message: "Select some text, then press the Tsubame shortcut again.",
                symbolName: "text.cursor"
            )
        case .unsupportedApplication:
            Self(
                kind: .unsupportedApplication,
                title: "Selection unavailable in this app",
                message: "This app does not provide its text selection through macOS Accessibility.",
                symbolName: "accessibility"
            )
        case .permissionDenied:
            Self(
                kind: .permissionDenied,
                title: "Accessibility access needed",
                message: "Enable Tsubame in System Settings → Privacy & Security → Accessibility.",
                symbolName: "hand.raised.fill"
            )
        case .accessibilityTimedOut:
            Self(
                kind: .accessibilityTimedOut,
                title: "The app did not respond",
                message: "The focused app did not answer the Accessibility request in time. Try again.",
                symbolName: "clock"
            )
        case .noFocusedApplication, .noFocusedElement:
            Self(
                kind: .accessibilityError,
                title: "No readable selection",
                message: error.localizedDescription,
                symbolName: "exclamationmark.magnifyingglass"
            )
        case .invalidAccessibilityValue, .invalidTextRange:
            Self(
                kind: .accessibilityError,
                title: "Could not read the selection",
                message: error.localizedDescription,
                symbolName: "exclamationmark.triangle"
            )
        }
    }
}

struct HotKeyFeedbackState: Equatable {
    struct Item: Equatable {
        let requestID: UInt64
        let presentation: HotKeyFeedbackPresentation
        let generation: UInt64
    }

    private(set) var item: Item?
    private var nextGeneration: UInt64 = 0

    @discardableResult
    mutating func present(
        _ presentation: HotKeyFeedbackPresentation,
        requestID: UInt64
    ) -> UInt64 {
        nextGeneration &+= 1
        item = Item(
            requestID: requestID,
            presentation: presentation,
            generation: nextGeneration
        )
        return nextGeneration
    }

    @discardableResult
    mutating func dismiss(generation: UInt64) -> Bool {
        guard item?.generation == generation else { return false }
        item = nil
        return true
    }

    mutating func clear() {
        item = nil
    }
}
