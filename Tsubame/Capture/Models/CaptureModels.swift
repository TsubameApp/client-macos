import CoreGraphics
import Foundation

enum CaptureMethod: String, Sendable, Equatable {
    case accessibility
    case clipboard
}

enum CaptureAnchorCoordinateSpace: String, Sendable, Equatable {
    case accessibilityTopLeft
    case appKitBottomLeft
}

struct CaptureTextRange: Sendable, Equatable, Hashable {
    let start: Int
    let end: Int

    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    static func fullRange(of text: String) -> Self {
        Self(start: 0, end: text.utf8.count)
    }

    static func fromUTF16Range(_ range: NSRange, in text: String) throws -> Self {
        guard range.location != NSNotFound,
              let stringRange = Range(range, in: text),
              let lowerUTF8 = stringRange.lowerBound.samePosition(in: text.utf8),
              let upperUTF8 = stringRange.upperBound.samePosition(in: text.utf8)
        else {
            throw CaptureError.invalidTextRange
        }

        return Self(
            start: text.utf8.distance(from: text.utf8.startIndex, to: lowerUTF8),
            end: text.utf8.distance(from: text.utf8.startIndex, to: upperUTF8)
        )
    }

    func substring(in text: String) -> String? {
        guard start >= 0, end >= start, end <= text.utf8.count else { return nil }
        let lowerUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: start)
        let upperUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: end)
        guard let lower = String.Index(lowerUTF8, within: text),
              let upper = String.Index(upperUTF8, within: text)
        else {
            return nil
        }
        return String(text[lower..<upper])
    }
}

struct SourceApplication: Sendable, Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let localizedName: String?
}

struct CaptureSnapshot: Sendable, Equatable {
    let text: String
    let selectedRange: CaptureTextRange
    /// Global Accessibility screen coordinates (origin at the top-left of the main display).
    let anchorRectangle: CGRect?
    let anchorCoordinateSpace: CaptureAnchorCoordinateSpace
    let sourceApplication: SourceApplication
    let method: CaptureMethod
    let contextSource: CaptureContextSource
    let timestamp: Date

    init(
        text: String,
        selectedRange: CaptureTextRange,
        anchorRectangle: CGRect?,
        anchorCoordinateSpace: CaptureAnchorCoordinateSpace = .accessibilityTopLeft,
        sourceApplication: SourceApplication,
        method: CaptureMethod,
        contextSource: CaptureContextSource = .selectionOnly,
        timestamp: Date = .now
    ) throws {
        guard !text.isEmpty else { throw CaptureError.noSelection }
        guard selectedRange.substring(in: text) != nil else {
            throw CaptureError.invalidTextRange
        }

        self.text = text
        self.selectedRange = selectedRange
        self.anchorRectangle = anchorRectangle
        self.anchorCoordinateSpace = anchorCoordinateSpace
        self.sourceApplication = sourceApplication
        self.method = method
        self.contextSource = contextSource
        self.timestamp = timestamp
    }
}

enum CaptureError: LocalizedError, Sendable, Equatable {
    case permissionDenied
    case noFocusedApplication
    case noFocusedElement
    case noSelection
    case unsupportedApplication
    case accessibilityTimedOut
    case invalidAccessibilityValue
    case invalidTextRange

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Accessibility permission is required to capture selected text."
        case .noFocusedApplication:
            "No focused application was found."
        case .noFocusedElement:
            "No focused text element was found."
        case .noSelection:
            "Select some text before using the Tsubame shortcut."
        case .unsupportedApplication:
            "The focused application does not expose its selection through Accessibility."
        case .accessibilityTimedOut:
            "The focused application did not answer the Accessibility request in time."
        case .invalidAccessibilityValue:
            "The focused application returned invalid Accessibility data."
        case .invalidTextRange:
            "The captured selection range is invalid for its text."
        }
    }
}

protocol CaptureProvider: Sendable {
    func capture(requestID: UInt64) async throws -> CaptureSnapshot
}
