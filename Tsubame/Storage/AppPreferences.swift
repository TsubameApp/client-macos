import Foundation

final class AppPreferences {
    private enum Key {
        static let onboardingCompleted = "onboardingCompleted"
        static let developerModeEnabled = "developerModeEnabled"
        static let activeDictionaryID = "activeDictionaryID"
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

    var activeDictionaryID: UUID? {
        get {
            defaults.string(forKey: Key.activeDictionaryID)
                .flatMap(UUID.init(uuidString:))
        }
        set {
            defaults.set(
                newValue?.uuidString.lowercased(),
                forKey: Key.activeDictionaryID
            )
        }
    }
}
