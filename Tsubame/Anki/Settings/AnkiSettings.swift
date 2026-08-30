import Foundation

struct AnkiSettings: Codable, Sendable, Equatable {
    var enabled: Bool
    var endpoint: String
    var deckName: String
    var modelName: String
    var tags: [String]
    var fieldTemplates: [String: String]
    var modelFieldNames: [String]
    var mappingVersion: Int

    static let defaults = Self(
        enabled: false,
        endpoint: AnkiConnectEndpoint.defaultValue,
        deckName: "",
        modelName: "",
        tags: ["tsubame"],
        fieldTemplates: [:],
        modelFieldNames: [],
        mappingVersion: 3
    )

    init(
        enabled: Bool,
        endpoint: String,
        deckName: String,
        modelName: String,
        tags: [String],
        fieldTemplates: [String: String],
        modelFieldNames: [String] = [],
        mappingVersion: Int = 3
    ) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.deckName = deckName
        self.modelName = modelName
        self.tags = tags
        self.fieldTemplates = fieldTemplates
        self.modelFieldNames = modelFieldNames
        self.mappingVersion = mappingVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        deckName = try container.decode(String.self, forKey: .deckName)
        modelName = try container.decode(String.self, forKey: .modelName)
        tags = try container.decode([String].self, forKey: .tags)
        fieldTemplates = try container.decode([String: String].self, forKey: .fieldTemplates)
        modelFieldNames = try container.decodeIfPresent(
            [String].self,
            forKey: .modelFieldNames
        ) ?? Array(fieldTemplates.keys).sorted()
        mappingVersion = try container.decodeIfPresent(Int.self, forKey: .mappingVersion) ?? 0
    }
}

@MainActor
final class AnkiSettingsStore {
    private static let key = "ankiSettings"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AnkiSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(AnkiSettings.self, from: data)
        else {
            return .defaults
        }
        var migrated = settings
        if migrated.mappingVersion < 1 {
            for field in migrated.fieldTemplates.keys where
                migrated.fieldTemplates[field] == "{definition}"
                    && Self.isDefinitionField(field) {
                migrated.fieldTemplates[field] = "{definitions}"
            }
        }
        if migrated.mappingVersion < 2 {
            for field in migrated.fieldTemplates.keys where
                migrated.fieldTemplates[field] == "{reading}"
                    && Self.isFuriganaField(field) {
                migrated.fieldTemplates[field] = "{furigana}"
            }
        }
        if migrated.mappingVersion < 3 {
            for field in migrated.fieldTemplates.keys where
                migrated.fieldTemplates[field] == "{definitions}"
                    && Self.isBasicBackField(field) {
                migrated.fieldTemplates[field] = "{reading}<br>{definitions}"
            }
        }
        guard migrated.mappingVersion < 3 || migrated != settings else {
            return settings
        }
        migrated.mappingVersion = 3
        save(migrated)
        return migrated
    }

    func save(_ settings: AnkiSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func isDefinitionField(_ field: String) -> Bool {
        let normalized = field.lowercased().filter { $0.isLetter || $0.isNumber }
        return [
            "definition", "maindefinition", "primarydefinition", "glossary", "back",
            "wordmeaning", "wordmeaningrussian"
        ].contains(normalized)
    }

    private static func isFuriganaField(_ field: String) -> Bool {
        let normalized = field.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["wordreading", "expressionfurigana", "wordfurigana", "furigana"]
            .contains(normalized)
    }

    private static func isBasicBackField(_ field: String) -> Bool {
        field.lowercased().filter { $0.isLetter || $0.isNumber } == "back"
    }
}
