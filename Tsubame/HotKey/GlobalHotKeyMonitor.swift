import AppKit
import Carbon.HIToolbox
import OSLog

private let tsubameHotKeySignature: OSType = 0x5453424D // "TSBM"

enum GlobalHotKeyError: Error, Equatable, LocalizedError {
    case invalid(ShortcutValidationError)
    case conflict
    case eventHandler(OSStatus)
    case registration(OSStatus)
    case notStarted

    var errorDescription: String? {
        switch self {
        case .invalid(let error):
            error.localizedDescription
        case .conflict:
            "That shortcut is already in use by macOS or another application."
        case .eventHandler:
            "Tsubame could not install its global shortcut handler."
        case .registration:
            "Tsubame could not register that global shortcut."
        case .notStarted:
            "The global shortcut handler has not started."
        }
    }
}

@MainActor
protocol GlobalHotKeyMonitoring: AnyObject {
    var activeShortcut: Shortcut? { get }

    @discardableResult
    func start(
        shortcut: Shortcut,
        handler: @escaping () -> Void
    ) -> Result<Void, GlobalHotKeyError>

    @discardableResult
    func update(shortcut: Shortcut) -> Result<Void, GlobalHotKeyError>

    func stop()
}

@MainActor
final class HotKeyRegistrationToken {
    let id: UInt32
    private var unregisterAction: (() -> OSStatus)?

    init(id: UInt32, unregister: @escaping () -> OSStatus) {
        self.id = id
        unregisterAction = unregister
    }

    @discardableResult
    func unregister() -> OSStatus {
        guard let unregisterAction else { return noErr }
        self.unregisterAction = nil
        return unregisterAction()
    }
}

@MainActor
final class HotKeyEventHandlerToken {
    private var removeAction: (() -> OSStatus)?
    private let retainedContext: AnyObject?

    init(retaining context: AnyObject? = nil, remove: @escaping () -> OSStatus) {
        retainedContext = context
        removeAction = remove
    }

    @discardableResult
    func remove() -> OSStatus {
        guard let removeAction else { return noErr }
        self.removeAction = nil
        return removeAction()
    }
}

@MainActor
protocol HotKeySystemClient: AnyObject {
    func installEventHandler(
        receive: @escaping (UInt32) -> Void
    ) -> Result<HotKeyEventHandlerToken, GlobalHotKeyError>

    func register(
        shortcut: Shortcut,
        id: UInt32
    ) -> Result<HotKeyRegistrationToken, GlobalHotKeyError>
}

@MainActor
final class CarbonHotKeySystemClient: HotKeySystemClient {
    private final class HandlerContext {
        let receive: (UInt32) -> Void

        init(receive: @escaping (UInt32) -> Void) {
            self.receive = receive
        }
    }

    func installEventHandler(
        receive: @escaping (UInt32) -> Void
    ) -> Result<HotKeyEventHandlerToken, GlobalHotKeyError> {
        let context = HandlerContext(receive: receive)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandlerReference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var receivedID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard parameterStatus == noErr,
                      receivedID.signature == tsubameHotKeySignature else {
                    return OSStatus(eventNotHandledErr)
                }

                let context = Unmanaged<HandlerContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    context.receive(receivedID.id)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(context).toOpaque(),
            &eventHandlerReference
        )
        guard status == noErr, let eventHandlerReference else {
            return .failure(.eventHandler(status))
        }

        return .success(HotKeyEventHandlerToken(retaining: context) {
            RemoveEventHandler(eventHandlerReference)
        })
    }

    func register(
        shortcut: Shortcut,
        id: UInt32
    ) -> Result<HotKeyRegistrationToken, GlobalHotKeyError> {
        let hotKeyID = EventHotKeyID(
            signature: tsubameHotKeySignature,
            id: id
        )
        var hotKeyReference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.modifiers.carbonFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        guard status == noErr, let hotKeyReference else {
            if status == OSStatus(eventHotKeyExistsErr) {
                return .failure(.conflict)
            }
            return .failure(.registration(status))
        }

        return .success(HotKeyRegistrationToken(id: id) {
            UnregisterEventHotKey(hotKeyReference)
        })
    }
}

@MainActor
final class GlobalHotKeyMonitor: GlobalHotKeyMonitoring {
    private let system: any HotKeySystemClient
    private var registration: HotKeyRegistrationToken?
    private var eventHandler: HotKeyEventHandlerToken?
    private var handler: (() -> Void)?
    private var nextIdentifier: UInt32 = 1

    private(set) var activeShortcut: Shortcut?

    init(system: any HotKeySystemClient = CarbonHotKeySystemClient()) {
        self.system = system
    }

    @discardableResult
    func start(
        shortcut: Shortcut,
        handler: @escaping () -> Void
    ) -> Result<Void, GlobalHotKeyError> {
        guard eventHandler == nil else { return .success(()) }
        self.handler = handler

        switch system.installEventHandler(receive: { [weak self] id in
            self?.receiveHotKey(id: id)
        }) {
        case .success(let eventHandler):
            self.eventHandler = eventHandler
        case .failure(let error):
            self.handler = nil
            log(error: error, operation: "install handler")
            return .failure(error)
        }

        return update(shortcut: shortcut)
    }

    @discardableResult
    func update(shortcut: Shortcut) -> Result<Void, GlobalHotKeyError> {
        do {
            try shortcut.validate()
        } catch let error as ShortcutValidationError {
            return .failure(.invalid(error))
        } catch {
            return .failure(.registration(OSStatus(paramErr)))
        }

        guard eventHandler != nil else {
            return .failure(.notStarted)
        }
        guard shortcut != activeShortcut else {
            return .success(())
        }

        let identifier = takeNextIdentifier()
        switch system.register(shortcut: shortcut, id: identifier) {
        case .failure(let error):
            log(error: error, operation: "register")
            return .failure(error)
        case .success(let replacement):
            let previous = registration
            registration = replacement
            activeShortcut = shortcut

            if let previous {
                let status = previous.unregister()
                if status != noErr {
                    TsubameLogging.hotkey.error(
                        "Could not unregister previous global shortcut status=\(status, privacy: .public)"
                    )
                }
            }

            TsubameLogging.hotkey.notice(
                "Global shortcut registered shortcut=\(shortcut.displayName, privacy: .public)"
            )
            return .success(())
        }
    }

    func stop() {
        if let registration {
            let status = registration.unregister()
            if status != noErr {
                TsubameLogging.hotkey.error(
                    "Could not unregister global shortcut status=\(status, privacy: .public)"
                )
            }
        }
        if let eventHandler {
            let status = eventHandler.remove()
            if status != noErr {
                TsubameLogging.hotkey.error(
                    "Could not remove global shortcut handler status=\(status, privacy: .public)"
                )
            }
        }
        registration = nil
        eventHandler = nil
        activeShortcut = nil
        handler = nil
    }

    private func receiveHotKey(id: UInt32) {
        guard id == registration?.id else { return }
        TsubameLogging.hotkey.notice("Global shortcut received")
        handler?()
    }

    private func takeNextIdentifier() -> UInt32 {
        let identifier = nextIdentifier
        nextIdentifier = nextIdentifier == UInt32.max ? 1 : nextIdentifier + 1
        return identifier
    }

    private func log(error: GlobalHotKeyError, operation: String) {
        TsubameLogging.hotkey.error(
            "Could not \(operation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }
}
