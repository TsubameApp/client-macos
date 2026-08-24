import Foundation

struct AnkiSettings: Codable, Sendable, Equatable {
    var enabled: Bool
    var endpoint: String
    var deckName: String
    var modelName: String
    var tags: [String]
    var fieldTemplates: [String: String]
    var modelFieldNames: [String]

    static let defaults = Self(
        enabled: false,
        endpoint: AnkiConnectEndpoint.defaultValue,
        deckName: "",
        modelName: "",
        tags: ["tsubame"],
        fieldTemplates: [:],
        modelFieldNames: []
    )

    init(
        enabled: Bool,
        endpoint: String,
        deckName: String,
        modelName: String,
        tags: [String],
        fieldTemplates: [String: String],
        modelFieldNames: [String] = []
    ) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.deckName = deckName
        self.modelName = modelName
        self.tags = tags
        self.fieldTemplates = fieldTemplates
        self.modelFieldNames = modelFieldNames
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
        return settings
    }

    func save(_ settings: AnkiSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
