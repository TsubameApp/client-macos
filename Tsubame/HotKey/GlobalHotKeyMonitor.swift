import AppKit
import Carbon.HIToolbox
import OSLog

private let tsubameHotKeySignature: OSType = 0x5453424D // "TSBM"
private let tsubameHotKeyIdentifier: UInt32 = 1

@MainActor
final class GlobalHotKeyMonitor {
    static let displayName = "⌃⌥⌘D"

    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var handler: (() -> Void)?

    func start(handler: @escaping () -> Void) {
        guard hotKeyReference == nil, eventHandlerReference == nil else { return }
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
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
                      receivedID.signature == tsubameHotKeySignature,
                      receivedID.id == tsubameHotKeyIdentifier
                else {
                    return OSStatus(eventNotHandledErr)
                }

                let monitor = Unmanaged<GlobalHotKeyMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    monitor.receiveHotKey()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerReference
        )
        guard installStatus == noErr else {
            self.handler = nil
            TsubameLogging.hotkey.error(
                "Could not install hot key event handler status=\(installStatus, privacy: .public)"
            )
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: tsubameHotKeySignature,
            id: tsubameHotKeyIdentifier
        )
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            UInt32(controlKey | optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        guard registerStatus == noErr else {
            if let eventHandlerReference {
                RemoveEventHandler(eventHandlerReference)
            }
            eventHandlerReference = nil
            self.handler = nil
            TsubameLogging.hotkey.error(
                "Could not register global shortcut status=\(registerStatus, privacy: .public)"
            )
            return
        }

        TsubameLogging.hotkey.notice(
            "Global shortcut registered shortcut=\(Self.displayName, privacy: .public)"
        )
    }

    func stop() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
        hotKeyReference = nil
        eventHandlerReference = nil
        handler = nil
    }

    private func receiveHotKey() {
        TsubameLogging.hotkey.notice("Global shortcut received")
        handler?()
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }
}
