import Carbon.HIToolbox
import Foundation
import Testing
@testable import Tsubame

struct ShortcutTests {
    @Test
    func validatesSupportedShortcutsAndRejectsUnsafeShapes() throws {
        try Shortcut.defaultLookup.validate()
        try Shortcut(
            keyCode: UInt16(kVK_F8),
            modifiers: [.option]
        ).validate()

        #expect(throws: ShortcutValidationError.missingPrimaryModifier) {
            try Shortcut(
                keyCode: UInt16(kVK_ANSI_A),
                modifiers: [.shift]
            ).validate()
        }
        #expect(throws: ShortcutValidationError.modifierOnly) {
            try Shortcut(
                keyCode: UInt16(kVK_Command),
                modifiers: [.command]
            ).validate()
        }
        #expect(throws: ShortcutValidationError.unsupportedKey) {
            try Shortcut(keyCode: 128, modifiers: [.control]).validate()
        }
        #expect(throws: ShortcutValidationError.unsupportedModifiers) {
            try Shortcut(
                keyCode: UInt16(kVK_ANSI_A),
                modifiers: ShortcutModifiers(rawValue: 0xff)
            ).validate()
        }
    }

    @Test
    func formatsModifiersAndSpecialKeysInStableOrder() {
        let shortcut = Shortcut(
            keyCode: UInt16(kVK_F8),
            modifiers: [.command, .shift, .control, .option]
        )

        #expect(shortcut.displayName == "⌃⌥⇧⌘F8")
    }

    @Test
    func preferencesPersistShortcutAndFallBackFromInvalidData() throws {
        let suiteName = "TsubameShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let shortcut = Shortcut(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: [.control, .shift]
        )

        #expect(preferences.globalShortcut == .defaultLookup)
        preferences.globalShortcut = shortcut
        #expect(AppPreferences(defaults: defaults).globalShortcut == shortcut)

        defaults.set(128, forKey: "globalShortcutKeyCode")
        #expect(AppPreferences(defaults: defaults).globalShortcut == .defaultLookup)

        defaults.set(Int(kVK_ANSI_K), forKey: "globalShortcutKeyCode")
        defaults.set(0xff, forKey: "globalShortcutModifiers")
        #expect(AppPreferences(defaults: defaults).globalShortcut == .defaultLookup)

        defaults.removeObject(forKey: "globalShortcutModifiers")
        #expect(AppPreferences(defaults: defaults).globalShortcut == .defaultLookup)
    }

    @Test @MainActor
    func successfulReregistrationRegistersReplacementBeforeRemovingPrevious() throws {
        let system = RecordingHotKeySystemClient()
        let monitor = GlobalHotKeyMonitor(system: system)
        let replacement = Shortcut(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: [.control, .option]
        )

        try monitor.start(shortcut: .defaultLookup) {}.get()
        try monitor.update(shortcut: replacement).get()

        #expect(monitor.activeShortcut == replacement)
        #expect(system.events == [
            "install-handler",
            "register-1-\(Shortcut.defaultLookup.keyCode)",
            "register-2-\(replacement.keyCode)",
            "unregister-1",
        ])
    }

    @Test @MainActor
    func conflictPreservesPreviousRegistrationAndShortcut() throws {
        let replacement = Shortcut(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: [.control, .option]
        )
        let system = RecordingHotKeySystemClient(failingShortcut: replacement)
        let monitor = GlobalHotKeyMonitor(system: system)

        try monitor.start(shortcut: .defaultLookup) {}.get()
        let result = monitor.update(shortcut: replacement)

        switch result {
        case .failure(.conflict):
            break
        default:
            Issue.record("Expected a shortcut conflict")
        }
        #expect(monitor.activeShortcut == .defaultLookup)
        #expect(!system.events.contains("unregister-1"))
    }

    @Test @MainActor
    func sameShortcutIsNoOpAndStaleEventIDsAreIgnored() throws {
        let system = RecordingHotKeySystemClient()
        let monitor = GlobalHotKeyMonitor(system: system)
        var receivedCount = 0
        let replacement = Shortcut(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: [.command, .option]
        )

        try monitor.start(shortcut: .defaultLookup) {
            receivedCount += 1
        }.get()
        try monitor.update(shortcut: .defaultLookup).get()
        #expect(system.events.filter { $0.hasPrefix("register-") }.count == 1)

        try monitor.update(shortcut: replacement).get()
        system.send(id: 1)
        system.send(id: 2)
        #expect(receivedCount == 1)

        monitor.stop()
        #expect(system.events.suffix(2) == ["unregister-2", "remove-handler"])
    }

    @Test @MainActor
    func modelPersistsOnlySuccessfullyRegisteredShortcut() throws {
        let suiteName = "TsubameShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let monitor = StubGlobalHotKeyMonitor(activeShortcut: .defaultLookup)
        let model = AppModel(hotKeyMonitor: monitor, preferences: preferences)
        let accepted = Shortcut(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: [.control, .option]
        )
        let rejected = Shortcut(
            keyCode: UInt16(kVK_ANSI_J),
            modifiers: [.control, .option]
        )

        #expect(model.updateGlobalShortcut(accepted))
        #expect(preferences.globalShortcut == accepted)

        monitor.nextUpdateResult = .failure(.conflict)
        #expect(!model.updateGlobalShortcut(rejected))
        #expect(model.globalShortcut == accepted)
        #expect(preferences.globalShortcut == accepted)
        #expect(model.globalShortcutError?.contains("remains active") == true)
    }
}

@MainActor
private final class RecordingHotKeySystemClient: HotKeySystemClient {
    private(set) var events: [String] = []
    private var receive: ((UInt32) -> Void)?
    private let failingShortcut: Shortcut?

    init(failingShortcut: Shortcut? = nil) {
        self.failingShortcut = failingShortcut
    }

    func installEventHandler(
        receive: @escaping (UInt32) -> Void
    ) -> Result<HotKeyEventHandlerToken, GlobalHotKeyError> {
        events.append("install-handler")
        self.receive = receive
        return .success(HotKeyEventHandlerToken { [weak self] in
            self?.events.append("remove-handler")
            return noErr
        })
    }

    func register(
        shortcut: Shortcut,
        id: UInt32
    ) -> Result<HotKeyRegistrationToken, GlobalHotKeyError> {
        events.append("register-\(id)-\(shortcut.keyCode)")
        if shortcut == failingShortcut {
            return .failure(.conflict)
        }
        return .success(HotKeyRegistrationToken(id: id) { [weak self] in
            self?.events.append("unregister-\(id)")
            return noErr
        })
    }

    func send(id: UInt32) {
        receive?(id)
    }
}

@MainActor
private final class StubGlobalHotKeyMonitor: GlobalHotKeyMonitoring {
    var activeShortcut: Shortcut?
    var nextUpdateResult: Result<Void, GlobalHotKeyError> = .success(())

    init(activeShortcut: Shortcut?) {
        self.activeShortcut = activeShortcut
    }

    func start(
        shortcut: Shortcut,
        handler: @escaping () -> Void
    ) -> Result<Void, GlobalHotKeyError> {
        activeShortcut = shortcut
        return .success(())
    }

    func update(shortcut: Shortcut) -> Result<Void, GlobalHotKeyError> {
        let result = nextUpdateResult
        if case .success = result {
            activeShortcut = shortcut
        }
        return result
    }

    func stop() {
        activeShortcut = nil
    }
}
