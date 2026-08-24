import Foundation

struct AnkiMiningConfiguration: Sendable, Equatable {
    let endpoint: URL
    let deckName: String
    let modelName: String
    let tags: [String]
    let modelFieldNames: [String]
    let fieldTemplates: [String: String]
}

enum AnkiFieldRenderingError: LocalizedError, Sendable, Equatable {
    case unknownMarker(String)
    case noMappedFields

    var errorDescription: String? {
        switch self {
        case .unknownMarker(let marker):
            "Unsupported Anki field marker: \(marker)"
        case .noMappedFields:
            "Map at least one Anki field before mining."
        }
    }
}

struct AnkiFieldRenderer: Sendable {
    func render(
        candidate: MiningCandidate,
        configuration: AnkiMiningConfiguration
    ) throws -> [String: String] {
        var rendered: [String: String] = [:]
        var hasContent = false
        for field in configuration.modelFieldNames {
            let value = try render(
                template: configuration.fieldTemplates[field, default: ""],
                candidate: candidate
            )
            rendered[field] = value
            hasContent = hasContent || !value.isEmpty
        }
        guard hasContent else { throw AnkiFieldRenderingError.noMappedFields }
        return rendered
    }

    func render(template: String, candidate: MiningCandidate) throws -> String {
        let replacements = values(for: candidate)
        let supportedMarkers = Set(replacements.map(\.0))
        if let unknown = markers(in: template).first(where: {
            !supportedMarkers.contains($0)
        }) {
            throw AnkiFieldRenderingError.unknownMarker(unknown)
        }
        var output = template
        for (marker, value) in replacements {
            output = output.replacingOccurrences(of: marker, with: value)
        }
        return output
    }

    private func values(for candidate: MiningCandidate) -> [(String, String)] {
        let definitions = candidate.definitions
            .map { "<li>\(escapeHTML($0))</li>" }
            .joined()
        let clozeSentence: String
        if let parts = candidate.clozeParts {
            clozeSentence = escapeHTML(parts.prefix)
                + "<b>\(escapeHTML(parts.body))</b>"
                + escapeHTML(parts.suffix)
        } else {
            clozeSentence = escapeHTML(candidate.selectedText)
        }

        return [
            ("{expression}", escapeHTML(candidate.expression)),
            ("{reading}", escapeHTML(candidate.reading)),
            ("{selection-text}", escapeHTML(candidate.selectedText)),
            ("{definition}", escapeHTML(candidate.definitions.first ?? "")),
            ("{definitions}", definitions.isEmpty ? "" : "<ol>\(definitions)</ol>"),
            ("{sentence}", escapeHTML(candidate.selectedText)),
            ("{cloze-sentence}", clozeSentence),
            ("{dictionary}", escapeHTML(candidate.dictionaryTitle)),
            ("{source-application}", escapeHTML(candidate.sourceApplication))
        ]
    }

    private func markers(in value: String) -> [String] {
        let pattern = #"\{[A-Za-z0-9-]+\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        return expression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

extension AnkiSettingsModel {
    func miningConfiguration() throws -> AnkiMiningConfiguration {
        guard enabled,
              !deckName.isEmpty,
              !modelName.isEmpty,
              !modelFieldNames.isEmpty
        else {
            throw AnkiMiningError.incompleteConfiguration
        }
        return AnkiMiningConfiguration(
            endpoint: try AnkiConnectEndpoint.validate(endpoint),
            deckName: deckName,
            modelName: modelName,
            tags: tagsText
                .split { $0.isWhitespace || $0 == "," }
                .map(String.init),
            modelFieldNames: modelFieldNames,
            fieldTemplates: fieldTemplates
        )
    }
}
