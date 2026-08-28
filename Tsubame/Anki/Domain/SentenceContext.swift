import Foundation
import TsubameCore

struct SentenceContext: Sendable, Equatable {
    let text: String
    let matchedRange: UTF8TextRange

    static func extract(from text: String, matchedRange: UTF8TextRange) -> Self? {
        guard let matchLower = index(matchedRange.start, in: text),
              let matchUpper = index(matchedRange.end, in: text),
              matchLower < matchUpper
        else {
            return nil
        }

        let terminators: Set<Character> = ["。", "！", "？", "!", "?", "\n", "\r"]
        var lower = matchLower
        while lower > text.startIndex {
            let previous = text.index(before: lower)
            if terminators.contains(text[previous]) { break }
            lower = previous
        }
        while lower < matchLower, text[lower].isWhitespace {
            lower = text.index(after: lower)
        }

        var upper = matchUpper
        while upper < text.endIndex {
            let character = text[upper]
            upper = text.index(after: upper)
            if terminators.contains(character) { break }
        }
        let closers: Set<Character> = ["」", "』", "）", "】", "”", "’"]
        while upper < text.endIndex, closers.contains(text[upper]) {
            upper = text.index(after: upper)
        }
        while upper > matchUpper, text[text.index(before: upper)].isWhitespace {
            upper = text.index(before: upper)
        }

        let sentence = String(text[lower..<upper])
        guard let lowerUTF8 = lower.samePosition(in: text.utf8),
              let matchLowerUTF8 = matchLower.samePosition(in: text.utf8),
              let matchUpperUTF8 = matchUpper.samePosition(in: text.utf8)
        else {
            return nil
        }
        let sentenceStart = text.utf8.distance(from: text.utf8.startIndex, to: lowerUTF8)
        return Self(
            text: sentence,
            matchedRange: UTF8TextRange(
                start: text.utf8.distance(from: text.utf8.startIndex, to: matchLowerUTF8) - sentenceStart,
                end: text.utf8.distance(from: text.utf8.startIndex, to: matchUpperUTF8) - sentenceStart
            )
        )
    }

    private static func index(_ offset: Int, in text: String) -> String.Index? {
        guard offset >= 0, offset <= text.utf8.count else { return nil }
        let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        return String.Index(utf8Index, within: text)
    }
}
