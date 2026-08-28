import Foundation
import Testing
import TsubameCore
@testable import Tsubame

struct AnkiFieldRendererTests {
    @Test
    func formatsAnkiFurigana() {
        let cases = [
            ("食べる", "たべる", "食[た]べる"),
            ("お祝い", "おいわい", "お祝[いわ]い"),
            ("申し込む", "もうしこむ", "申[もう]し込[こ]む"),
            ("今日", "きょう", "今日[きょう]"),
            ("かな", "かな", "かな")
        ]
        for (expression, reading, expected) in cases {
            #expect(
                AnkiFuriganaFormatter().format(
                    expression: expression,
                    reading: reading
                ) == expected
            )
        }
    }

    @Test
    func rendersEscapedFieldsAndUTF8Cloze() throws {
        let candidate = makeCandidate()
        let configuration = AnkiMiningConfiguration(
            endpoint: try AnkiConnectEndpoint.validate(AnkiConnectEndpoint.defaultValue),
            deckName: "Mining",
            modelName: "Kaishi 1.5k RU",
            tags: ["tsubame"],
            modelFieldNames: ["Word", "Meaning", "All Meanings", "Sentence", "Unused"],
            fieldTemplates: [
                "Word": "<b>{expression}</b>",
                "Meaning": "{definition}",
                "All Meanings": "{definitions}",
                "Sentence": "{cloze-sentence}"
            ]
        )

        let fields = try AnkiFieldRenderer().render(
            candidate: candidate,
            configuration: configuration
        )

        #expect(fields["Word"] == "<b>食べる</b>")
        #expect(fields["Meaning"] == "to eat &amp; enjoy")
        #expect(fields["All Meanings"] == "<ol><li>to eat &amp; enjoy</li><li>to consume</li></ol>")
        #expect(fields["Sentence"] == "彼は<b>食べ</b>ました。")
        #expect(fields["Unused"] == "")
    }

    @Test
    func rendersSafariSentenceContextOutsideSelection() throws {
        let entry = DictionaryEntry(
            id: 8,
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
                    text: "есть",
                    contentJSON: Data("null".utf8)
                )
            ]
        )
        let sentence = "ピザを食べるのが大好きです。"
        let candidate = MiningCandidate(
            entry: entry,
            selectedText: "食べる",
            contextText: sentence,
            matchedRange: UTF8TextRange(start: 9, end: 18),
            dictionaryTitle: "JMdict",
            sourceApplication: "Safari"
        )

        #expect(try AnkiFieldRenderer().render(
            template: "{sentence}",
            candidate: candidate
        ) == sentence)
        #expect(try AnkiFieldRenderer().render(
            template: "{cloze-sentence}",
            candidate: candidate
        ) == "ピザを<b>食べる</b>のが大好きです。")
        #expect(try AnkiFieldRenderer().render(
            template: "{furigana}",
            candidate: candidate
        ) == "食[た]べる")
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
            ),
            DictionaryDefinition(
                position: 1,
                kind: "text",
                text: "to consume",
                contentJSON: Data("null".utf8)
            )
        ]
    )
    return MiningCandidate(
        entry: entry,
        selectedText: "彼は食べました。",
        contextText: "前です。彼は食べました。次です。",
        matchedRange: UTF8TextRange(start: 18, end: 24),
        dictionaryTitle: "JMdict",
        sourceApplication: "Safari"
    )
}
