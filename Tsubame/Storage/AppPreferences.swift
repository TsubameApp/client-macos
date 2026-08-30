import Foundation

final class AppPreferences {
    private enum Key {
        static let onboardingCompleted = "onboardingCompleted"
        static let developerModeEnabled = "developerModeEnabled"
        static let enabledDictionaryIDs = "enabledDictionaryIDs"
        static let dictionaryOrderIDs = "dictionaryOrderIDs"
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

    var dictionaryOrderIDs: [UUID]? {
        get {
            guard let values = defaults.stringArray(forKey: Key.dictionaryOrderIDs) else {
                return nil
            }
            return values.compactMap(UUID.init(uuidString:))
        }
        set {
            defaults.set(newValue?.map(\.uuidString), forKey: Key.dictionaryOrderIDs)
        }
    }
}

struct DictionaryOrder {
    static func reconcile(
        preferred: [UUID],
        installed: [UUID],
        appending newIDs: [UUID] = []
    ) -> [UUID] {
        let installedSet = Set(installed)
        let newIDSet = Set(newIDs)
        var seen: Set<UUID> = []
        var result: [UUID] = []

        func append(_ id: UUID) {
            guard installedSet.contains(id), seen.insert(id).inserted else { return }
            result.append(id)
        }

        for id in preferred where !newIDSet.contains(id) { append(id) }
        for id in installed where !newIDSet.contains(id) { append(id) }
        for id in newIDs { append(id) }
        for id in installed { append(id) }
        return result
    }

    static func moving(_ order: [UUID], id: UUID, offset: Int) -> [UUID] {
        guard let sourceIndex = order.firstIndex(of: id) else { return order }
        let destinationIndex = sourceIndex + offset
        guard order.indices.contains(destinationIndex) else { return order }
        var moved = order
        moved.swapAt(sourceIndex, destinationIndex)
        return moved
    }
}
