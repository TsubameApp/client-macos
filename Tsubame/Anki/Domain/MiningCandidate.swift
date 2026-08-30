import Foundation
import TsubameCore

struct MiningCandidate: Sendable, Equatable {
    let expression: String
    let reading: String
    let selectedText: String
    let sentence: String
    let sentenceMatchedRange: UTF8TextRange
    let definitions: [String]
    let dictionaryTitle: String
    let sourceApplication: String

    init(
        entry: DictionaryEntry,
        selectedText: String,
        contextText: String,
        matchedRange: UTF8TextRange,
        dictionaryTitle: String,
        sourceApplication: String
    ) {
        expression = entry.expression
        reading = entry.reading
        self.selectedText = selectedText
        let context = SentenceContext.extract(
            from: contextText,
            matchedRange: matchedRange
        ) ?? SentenceContext(
            text: selectedText,
            matchedRange: .init(start: 0, end: selectedText.utf8.count)
        )
        sentence = context.text
        sentenceMatchedRange = context.matchedRange
        definitions = entry.definitions.compactMap(\.text)
        self.dictionaryTitle = dictionaryTitle
        self.sourceApplication = sourceApplication
    }

    var matchedText: String? {
        substring(in: sentence, range: sentenceMatchedRange)
    }

    var clozeParts: (prefix: String, body: String, suffix: String)? {
        guard let lower = utf8Index(sentenceMatchedRange.start, in: sentence),
              let upper = utf8Index(sentenceMatchedRange.end, in: sentence),
              lower <= upper
        else {
            return nil
        }
        return (
            String(sentence[..<lower]),
            String(sentence[lower..<upper]),
            String(sentence[upper...])
        )
    }

    private func substring(in text: String, range: UTF8TextRange) -> String? {
        guard let lower = utf8Index(range.start, in: text),
              let upper = utf8Index(range.end, in: text),
              lower <= upper
        else {
            return nil
        }
        return String(text[lower..<upper])
    }

    private func utf8Index(_ offset: Int, in text: String) -> String.Index? {
        guard offset >= 0, offset <= text.utf8.count else { return nil }
        let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        return String.Index(utf8Index, within: text)
    }
}
