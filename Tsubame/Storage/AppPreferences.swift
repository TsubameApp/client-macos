import Foundation

final class AppPreferences {
    private enum Key {
        static let onboardingCompleted = "onboardingCompleted"
        static let developerModeEnabled = "developerModeEnabled"
        static let enabledDictionaryIDs = "enabledDictionaryIDs"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
    }

    var developerModeEnabled: Bool {
        get { defaults.bool(forKey: Key.developerModeEnabled) }
        set { defaults.set(newValue, forKey: Key.developerModeEnabled) }
    }

    var enabledDictionaryIDs: Set<UUID>? {
        get {
            guard let values = defaults.stringArray(forKey: Key.enabledDictionaryIDs) else {
                return nil
            }
            return Set(values.compactMap(UUID.init(uuidString:)))
        }
        set {
            defaults.set(
                newValue?.map(\.uuidString).sorted(),
                forKey: Key.enabledDictionaryIDs
            )
        }
    }
}
