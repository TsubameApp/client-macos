import Foundation

enum CaptureContextSource: String, Sendable, Equatable {
    case sentenceTextMarker
    case elementValue
    case selectionOnly
}

struct CaptureTextContext: Sendable, Equatable {
    let text: String
    let selectedRange: CaptureTextRange
    let source: CaptureContextSource

    static func resolve(
        selectedText: String,
        fullText: String?,
        selectedUTF16Range: NSRange?,
        fullTextSource: CaptureContextSource = .elementValue
    ) -> Self {
        guard let fullText, !fullText.isEmpty else {
            return selectionOnly(selectedText)
        }

        if let selectedUTF16Range,
           let range = try? CaptureTextRange.fromUTF16Range(
               selectedUTF16Range,
               in: fullText
           ), range.substring(in: fullText) == selectedText {
            return Self(
                text: fullText,
                selectedRange: range,
                source: fullTextSource
            )
        }

        let matches = fullText.ranges(of: selectedText)
        guard matches.count == 1, let match = matches.first,
              let lower = match.lowerBound.samePosition(in: fullText.utf8),
              let upper = match.upperBound.samePosition(in: fullText.utf8)
        else {
            return selectionOnly(selectedText)
        }
        return Self(
            text: fullText,
            selectedRange: CaptureTextRange(
                start: fullText.utf8.distance(from: fullText.utf8.startIndex, to: lower),
                end: fullText.utf8.distance(from: fullText.utf8.startIndex, to: upper)
            ),
            source: fullTextSource
        )
    }

    private static func selectionOnly(_ selectedText: String) -> Self {
        Self(
            text: selectedText,
            selectedRange: .fullRange(of: selectedText),
            source: .selectionOnly
        )
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var cursor = startIndex
        while cursor < endIndex,
              let range = range(of: needle, range: cursor..<endIndex) {
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }
}
