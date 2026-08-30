import Foundation
import Testing
@testable import Tsubame

@MainActor
struct AnkiSettingsTests {
    @Test
    func persistsAnkiConfiguration() throws {
        let suiteName = "AnkiSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AnkiSettingsStore(defaults: defaults)
        let settings = AnkiSettings(
            enabled: true,
            endpoint: "http://localhost:8765",
            deckName: "Mining",
            modelName: "Lapis",
            tags: ["tsubame", "japanese"],
            fieldTemplates: ["Expression": "{expression}"]
        )

        store.save(settings)

        #expect(store.load() == settings)
    }

    @Test
    func migratesSettingsSavedBeforeModelFieldsWerePersisted() throws {
        let legacyJSON = Data(
            """
            {
              "enabled": true,
              "endpoint": "http://127.0.0.1:8765",
              "deckName": "Mining",
              "modelName": "Lapis",
              "tags": ["tsubame"],
              "fieldTemplates": {
                "Sentence": "{cloze-sentence}",
                "Expression": "{expression}"
              }
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(AnkiSettings.self, from: legacyJSON)

        #expect(settings.modelFieldNames == ["Expression", "Sentence"])
    }

    @Test
    func migratesAutoMappedDefinitionFieldToAllDefinitions() throws {
        let suiteName = "AnkiSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data(
            """
            {
              "enabled": true,
              "endpoint": "http://127.0.0.1:8765",
              "deckName": "Mining",
              "modelName": "Lapis",
              "tags": ["tsubame"],
              "fieldTemplates": {
                "Word Meaning (Russian)": "{definition}",
                "Word Reading": "{reading}"
              },
              "modelFieldNames": ["Word Meaning (Russian)", "Word Reading"]
            }
            """.utf8
        ), forKey: "ankiSettings")

        let settings = AnkiSettingsStore(defaults: defaults).load()

        #expect(settings.fieldTemplates["Word Meaning (Russian)"] == "{definitions}")
        #expect(settings.fieldTemplates["Word Reading"] == "{furigana}")
        #expect(settings.mappingVersion == 3)
    }

    @Test
    func loadsDecksModelsAndSuggestedFieldMappings() async throws {
        let suiteName = "AnkiSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = StaticAnkiConnectService()
        let model = AnkiSettingsModel(
            store: AnkiSettingsStore(defaults: defaults),
            clientProvider: { _ in service }
        )
        model.enabled = true

        await model.testConnection()
        await model.selectModel("Lapis")
        model.deckName = "Mining"

        #expect(model.connectionState == .connected(version: 6))
        #expect(model.deckNames == ["Default", "Mining"])
        #expect(model.modelNames == ["JP Mining Note", "Lapis"])
        #expect(
            model.modelFieldNames
                == ["Word", "Word Reading", "Word Meaning (Russian)", "Sentence"]
        )
        #expect(model.fieldTemplates["Word"] == "{expression}")
        #expect(model.fieldTemplates["Word Reading"] == "{furigana}")
        #expect(model.fieldTemplates["Word Meaning (Russian)"] == "{definitions}")
        #expect(model.fieldTemplates["Sentence"] == "{cloze-sentence}")

        let reloaded = AnkiSettingsStore(defaults: defaults).load()
        #expect(reloaded.enabled)
        #expect(reloaded.deckName == "Mining")
        #expect(reloaded.modelName == "Lapis")
        #expect(reloaded.fieldTemplates == model.fieldTemplates)
        #expect(model.mappingIssues.isEmpty)
    }

    @Test
    func basicFrontBackMappingIsSuggestedAndMiningReady() async throws {
        let suiteName = "AnkiSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AnkiSettingsModel(
            store: AnkiSettingsStore(defaults: defaults),
            clientProvider: { _ in BasicAnkiConnectService() }
        )
        model.enabled = true

        await model.testConnection()
        await model.selectModel("Basic")
        model.deckName = "Default"

        #expect(model.fieldTemplates["Front"] == "{expression}")
        #expect(model.fieldTemplates["Back"] == "{reading}<br>{definitions}")
        #expect(model.mappingIssues.isEmpty)
        #expect(try model.miningConfiguration().modelName == "Basic")
    }

    @Test
    func migratesOnlyAutomaticBasicBackMapping() throws {
        let suiteName = "AnkiSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AnkiSettingsStore(defaults: defaults)
        store.save(AnkiSettings(
            enabled: true,
            endpoint: AnkiConnectEndpoint.defaultValue,
            deckName: "Default",
            modelName: "Basic",
            tags: ["tsubame"],
            fieldTemplates: [
                "Front": "<b>{expression}</b>",
                "Back": "{definitions}",
                "Extra": "Custom {definitions}"
            ],
            modelFieldNames: ["Front", "Back", "Extra"],
            mappingVersion: 2
        ))

        let migrated = store.load()

        #expect(migrated.fieldTemplates["Front"] == "<b>{expression}</b>")
        #expect(migrated.fieldTemplates["Back"] == "{reading}<br>{definitions}")
        #expect(migrated.fieldTemplates["Extra"] == "Custom {definitions}")
        #expect(migrated.mappingVersion == 3)
    }
}

private struct StaticAnkiConnectService: AnkiConnectServing {
    func version() async throws -> Int { 6 }

    func deckNames() async throws -> [String] {
        ["Mining", "Default"]
    }

    func modelNames() async throws -> [String] {
        ["Lapis", "JP Mining Note"]
    }

    func modelFieldNames(modelName: String) async throws -> [String] {
        ["Word", "Word Reading", "Word Meaning (Russian)", "Sentence"]
    }

    func canAddNote(_ note: AnkiNote) async throws -> Bool { true }

    func addNote(_ note: AnkiNote) async throws -> Int64 { 1 }
}

private struct BasicAnkiConnectService: AnkiConnectServing {
    func version() async throws -> Int { 6 }
    func deckNames() async throws -> [String] { ["Default"] }
    func modelNames() async throws -> [String] { ["Basic"] }
    func modelFieldNames(modelName: String) async throws -> [String] {
        ["Front", "Back"]
    }
    func canAddNote(_ note: AnkiNote) async throws -> Bool { true }
    func addNote(_ note: AnkiNote) async throws -> Int64 { 1 }
}
