import Foundation

struct AnkiFuriganaFormatter: Sendable {
    func format(expression: String, reading: String) -> String {
        guard !expression.isEmpty, !reading.isEmpty,
              normalizedKana(expression) != normalizedKana(reading)
        else {
            return expression
        }

        let tokens = tokenize(expression)
        let readingCharacters = Array(reading)
        let normalizedReading = Array(normalizedKana(reading))
        guard let pieces = align(
            tokens: tokens,
            tokenIndex: 0,
            readingIndex: 0,
            reading: readingCharacters,
            normalizedReading: normalizedReading
        ) else {
            return "\(expression)[\(reading)]"
        }
        return pieces.map { piece in
            piece.reading.map { "\(piece.text)[\($0)]" } ?? piece.text
        }.joined()
    }

    private struct Token {
        let text: String
        let isKana: Bool
    }

    private struct Piece {
        let text: String
        let reading: String?
    }

    private func align(
        tokens: [Token],
        tokenIndex: Int,
        readingIndex: Int,
        reading: [Character],
        normalizedReading: [Character]
    ) -> [Piece]? {
        guard tokenIndex < tokens.count else {
            return readingIndex == reading.count ? [] : nil
        }
        let token = tokens[tokenIndex]
        if token.isKana {
            let expected = Array(normalizedKana(token.text))
            let end = readingIndex + expected.count
            guard end <= normalizedReading.count,
                  Array(normalizedReading[readingIndex..<end]) == expected,
                  let suffix = align(
                    tokens: tokens,
                    tokenIndex: tokenIndex + 1,
                    readingIndex: end,
                    reading: reading,
                    normalizedReading: normalizedReading
                  )
            else {
                return nil
            }
            return [Piece(text: token.text, reading: nil)] + suffix
        }

        guard readingIndex < reading.count else { return nil }
        for end in (readingIndex + 1)...reading.count {
            guard let suffix = align(
                tokens: tokens,
                tokenIndex: tokenIndex + 1,
                readingIndex: end,
                reading: reading,
                normalizedReading: normalizedReading
            ) else {
                continue
            }
            return [Piece(
                text: token.text,
                reading: String(reading[readingIndex..<end])
            )] + suffix
        }
        return nil
    }

    private func tokenize(_ expression: String) -> [Token] {
        var tokens: [Token] = []
        for character in expression {
            let kana = character.isJapaneseKana
            if let last = tokens.last, last.isKana == kana {
                tokens[tokens.count - 1] = Token(
                    text: last.text + String(character),
                    isKana: kana
                )
            } else {
                tokens.append(Token(text: String(character), isKana: kana))
            }
        }
        return tokens
    }

    private func normalizedKana(_ value: String) -> String {
        value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
    }
}

private extension Character {
    var isJapaneseKana: Bool {
        unicodeScalars.allSatisfy {
            (0x3040...0x30FF).contains(Int($0.value))
                || (0xFF66...0xFF9D).contains(Int($0.value))
        }
    }
}
