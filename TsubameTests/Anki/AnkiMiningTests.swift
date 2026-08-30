import Foundation
import Testing
import TsubameCore
@testable import Tsubame

struct AnkiMiningServiceTests {
    @Test
    func addsRenderedNoteAfterDuplicateCheck() async throws {
        let client = RecordingAnkiService(canAdd: true, noteID: 12345)
        let service = AnkiMiningService(clientProvider: { _ in client })

        let result = try await service.mine(
            miningCandidate(),
            configuration: try miningConfiguration()
        )

        #expect(result == .added(noteID: 12345))
        let calls = await client.calls
        #expect(calls == ["canAddNote", "addNote"])
        let note = try #require(await client.lastNote)
        #expect(note.deckName == "Mining")
        #expect(note.modelName == "Lapis")
        #expect(note.fields["Expression"] == "食べる")
        #expect(note.options.allowDuplicate == false)
        #expect(note.options.duplicateScope == "collection")
        #expect(note.tags == ["tsubame", "japanese"])
    }

    @Test
    func doesNotAddDuplicateNote() async throws {
        let client = RecordingAnkiService(canAdd: false, noteID: 1)
        let service = AnkiMiningService(clientProvider: { _ in client })

        let result = try await service.mine(
            miningCandidate(),
            configuration: try miningConfiguration()
        )

        #expect(result == .duplicate)
        #expect(await client.calls == ["canAddNote"])
    }
}

@MainActor
struct AnkiMiningModelTests {
    @Test
    func exposesAddedStateForPopupEntry() async throws {
        let suiteName = "AnkiMiningModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AnkiSettingsStore(defaults: defaults)
        store.save(
            AnkiSettings(
                enabled: true,
                endpoint: AnkiConnectEndpoint.defaultValue,
                deckName: "Mining",
                modelName: "Lapis",
                tags: ["tsubame"],
                fieldTemplates: [
                    "Expression": "{expression}",
                    "Reading": "{reading}",
                    "Meaning": "{definitions}",
                    "Sentence": "{cloze-sentence}"
                ],
                modelFieldNames: ["Expression", "Reading", "Meaning", "Sentence"]
            )
        )
        let settings = AnkiSettingsModel(store: store)
        let service = StubMiningService(result: .added(noteID: 99))
        let model = AnkiMiningModel(settings: settings, service: service)
        let entry = dictionaryEntry()
        let dictionaryID = UUID()

        let task = model.mine(
            requestID: 8,
            dictionaryID: dictionaryID,
            entry: entry,
            selectedText: "食べました",
            contextText: "食べました",
            matchedRange: UTF8TextRange(start: 0, end: 6),
            dictionaryTitle: "JMdict",
            sourceApplication: "Safari"
        )
        await task?.value

        #expect(model.state(
            requestID: 8,
            dictionaryID: dictionaryID,
            entryID: entry.id
        ) == .added(noteID: 99))
    }
}

private actor RecordingAnkiService: AnkiConnectServing {
    private let canAdd: Bool
    private let noteID: Int64
    private(set) var calls: [String] = []
    private(set) var lastNote: AnkiNote?

    init(canAdd: Bool, noteID: Int64) {
        self.canAdd = canAdd
        self.noteID = noteID
    }

    func version() async throws -> Int { 6 }
    func deckNames() async throws -> [String] { [] }
    func modelNames() async throws -> [String] { [] }
    func modelFieldNames(modelName: String) async throws -> [String] { [] }

    func canAddNote(_ note: AnkiNote) async throws -> Bool {
        calls.append("canAddNote")
        lastNote = note
        return canAdd
    }

    func addNote(_ note: AnkiNote) async throws -> Int64 {
        calls.append("addNote")
        lastNote = note
        return noteID
    }
}

private struct StubMiningService: AnkiMiningServing {
    let result: AnkiMiningResult

    func mine(
        _ candidate: MiningCandidate,
        configuration: AnkiMiningConfiguration
    ) async throws -> AnkiMiningResult {
        result
    }
}

private func miningConfiguration() throws -> AnkiMiningConfiguration {
    AnkiMiningConfiguration(
        endpoint: try AnkiConnectEndpoint.validate(AnkiConnectEndpoint.defaultValue),
        deckName: "Mining",
        modelName: "Lapis",
        tags: ["tsubame", "japanese"],
        modelFieldNames: ["Expression", "Sentence"],
        fieldTemplates: [
            "Expression": "{expression}",
            "Sentence": "{cloze-sentence}"
        ]
    )
}

private func miningCandidate() -> MiningCandidate {
    MiningCandidate(
        entry: dictionaryEntry(),
        selectedText: "食べました",
        contextText: "食べました",
        matchedRange: UTF8TextRange(start: 0, end: 6),
        dictionaryTitle: "JMdict",
        sourceApplication: "Safari"
    )
}

private func dictionaryEntry() -> DictionaryEntry {
    DictionaryEntry(
        id: 42,
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
                text: "to eat",
                contentJSON: Data("null".utf8)
            )
        ]
    )
}
