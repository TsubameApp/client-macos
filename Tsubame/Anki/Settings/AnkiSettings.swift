import Foundation

struct AnkiSettings: Codable, Sendable, Equatable {
    var enabled: Bool
    var endpoint: String
    var deckName: String
    var modelName: String
    var tags: [String]
    var fieldTemplates: [String: String]

    static let defaults = Self(
        enabled: false,
        endpoint: AnkiConnectEndpoint.defaultValue,
        deckName: "",
        modelName: "",
        tags: ["tsubame"],
        fieldTemplates: [:]
    )
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
