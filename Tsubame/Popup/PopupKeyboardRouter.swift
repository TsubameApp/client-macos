import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum PopupKeyboardCommand: Equatable, Sendable {
    case previousWord
    case nextWord
    case scrollUp
    case scrollDown
    case pageUp
    case pageDown
    case togglePin
    case dismiss
}

enum PopupKeyboardCommandMapper {
    static func command(
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> PopupKeyboardCommand? {
        let modifiers = flags.intersection([
            .maskCommand,
            .maskShift,
            .maskControl,
            .maskAlternate,
        ])

        switch Int(keyCode) {
        case kVK_LeftArrow where modifiers.isEmpty:
            return .previousWord
        case kVK_RightArrow where modifiers.isEmpty:
            return .nextWord
        case kVK_UpArrow where modifiers.isEmpty:
            return .scrollUp
        case kVK_DownArrow where modifiers.isEmpty:
            return .scrollDown
        case kVK_PageUp where modifiers.isEmpty:
            return .pageUp
        case kVK_PageDown where modifiers.isEmpty:
            return .pageDown
        case kVK_ANSI_P where modifiers == [.maskCommand, .maskShift]:
            return .togglePin
        case kVK_Escape where modifiers.isEmpty:
            return .dismiss
        default:
            return nil
        }
    }
}

@MainActor
protocol PopupKeyboardRouting: AnyObject {
    @discardableResult
    func start(
        handler: @escaping @MainActor @Sendable (PopupKeyboardCommand, Bool) -> Void
    ) -> Bool

    func stop()
}

@MainActor
final class PopupKeyboardRouter: PopupKeyboardRouting {
    private final class CallbackContext: @unchecked Sendable {
        var eventTap: CFMachPort?
        let handler: @MainActor (PopupKeyboardCommand, Bool) -> Void

        init(handler: @escaping @MainActor (PopupKeyboardCommand, Bool) -> Void) {
            self.handler = handler
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var callbackContext: CallbackContext?

    @discardableResult
    func start(
        handler: @escaping @MainActor @Sendable (PopupKeyboardCommand, Bool) -> Void
    ) -> Bool {
        guard eventTap == nil else { return true }

        let context = CallbackContext(handler: handler)
        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let context = Unmanaged<CallbackContext>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let eventTap = context.eventTap {
                        CGEvent.tapEnable(tap: eventTap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown,
                      let command = PopupKeyboardCommandMapper.command(
                        keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                        flags: event.flags
                      ) else {
                    return Unmanaged.passUnretained(event)
                }

                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                MainActor.assumeIsolated {
                    context.handler(command, isRepeat)
                }
                return nil
            },
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            CFMachPortInvalidate(eventTap)
            return false
        }

        context.eventTap = eventTap
        callbackContext = context
        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        callbackContext = nil
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }
}
