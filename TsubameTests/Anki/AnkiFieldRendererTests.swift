import Foundation
import Testing
import TsubameCore
@testable import Tsubame

struct AnkiFieldRendererTests {
    @Test
    func rendersEscapedFieldsAndUTF8Cloze() throws {
        let candidate = makeCandidate()
        let configuration = AnkiMiningConfiguration(
            endpoint: try AnkiConnectEndpoint.validate(AnkiConnectEndpoint.defaultValue),
            deckName: "Mining",
            modelName: "Kaishi 1.5k RU",
            tags: ["tsubame"],
            modelFieldNames: ["Word", "Meaning", "Sentence", "Unused"],
            fieldTemplates: [
                "Word": "<b>{expression}</b>",
                "Meaning": "{definition}",
                "Sentence": "{cloze-sentence}"
            ]
        )

        let fields = try AnkiFieldRenderer().render(
            candidate: candidate,
            configuration: configuration
        )

        #expect(fields["Word"] == "<b>食べる</b>")
        #expect(fields["Meaning"] == "to eat &amp; enjoy")
        #expect(fields["Sentence"] == "彼は<b>食べ</b>ました。")
        #expect(fields["Unused"] == "")
    }

    @Test
    func rejectsUnsupportedYomitanMarkers() throws {
        let candidate = makeCandidate()

        #expect(throws: AnkiFieldRenderingError.unknownMarker("{audio}")) {
            try AnkiFieldRenderer().render(
                template: "{expression} {audio}",
                candidate: candidate
            )
        }
    }

    @Test
    func doesNotInterpretMarkersInsideDictionaryContent() throws {
        let candidate = makeCandidate(definition: "literal {audio} text")

        let rendered = try AnkiFieldRenderer().render(
            template: "{definition}",
            candidate: candidate
        )

        #expect(rendered == "literal {audio} text")
    }

    @Test
    func rejectsCompletelyEmptyMappings() throws {
        let candidate = makeCandidate()
        let configuration = AnkiMiningConfiguration(
            endpoint: try AnkiConnectEndpoint.validate(AnkiConnectEndpoint.defaultValue),
            deckName: "Mining",
            modelName: "Basic",
            tags: [],
            modelFieldNames: ["Front", "Back"],
            fieldTemplates: [:]
        )

        #expect(throws: AnkiFieldRenderingError.noMappedFields) {
            try AnkiFieldRenderer().render(
                candidate: candidate,
                configuration: configuration
            )
        }
    }
}

private func makeCandidate(definition: String = "to eat & enjoy") -> MiningCandidate {
    let entry = DictionaryEntry(
        id: 7,
        expression: "食べる",
        reading: "たべる",
        definitionTags: nil,
        rules: "v1",
        score: 1,
        sequence: 1,
        termTags: "",
        matches: [],
        definitions: [
            DictionaryDefinition(
                position: 0,
                kind: "text",
                text: definition,
                contentJSON: Data("null".utf8)
            )
        ]
    )
    return MiningCandidate(
        entry: entry,
        selectedText: "彼は食べました。",
        matchedRange: UTF8TextRange(start: 6, end: 12),
        dictionaryTitle: "JMdict",
        sourceApplication: "Safari"
    )
}
