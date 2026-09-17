import AppKit
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    let shortcut: Shortcut
    let isRecording: Bool
    let beginRecording: () -> Void
    let cancelRecording: () -> Void
    let commit: (Shortcut) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.beginRecording)
        button.onCancel = { context.coordinator.cancelRecording() }
        button.onShortcut = { context.coordinator.commit($0) }
        button.setAccessibilityLabel("Global shortcut")
        button.setAccessibilityHelp("Press to record a new global shortcut.")
        context.coordinator.button = button
        context.coordinator.update(parent: self)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        context.coordinator.update(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        private var parent: ShortcutRecorderView
        weak var button: ShortcutRecorderButton?

        init(parent: ShortcutRecorderView) {
            self.parent = parent
        }

        func update(parent: ShortcutRecorderView) {
            self.parent = parent
            button?.isRecording = parent.isRecording
            button?.displayedShortcut = parent.shortcut
        }

        @objc func beginRecording() {
            parent.beginRecording()
            button?.startRecording()
        }

        func cancelRecording() {
            parent.cancelRecording()
        }

        func commit(_ shortcut: Shortcut) -> Bool {
            parent.commit(shortcut)
        }
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var displayedShortcut: Shortcut = .defaultLookup {
        didSet { updateTitle() }
    }
    var isRecording = false {
        didSet { updateTitle() }
    }
    var onCancel: (() -> Void)?
    var onShortcut: ((Shortcut) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat else { return }

        let modifiers = ShortcutModifiers(eventFlags: event.modifierFlags)
        if event.keyCode == 53, modifiers.isEmpty {
            isRecording = false
            onCancel?()
            window?.makeFirstResponder(nil)
            return
        }

        let candidate = Shortcut(keyCode: event.keyCode, modifiers: modifiers)
        if onShortcut?(candidate) == true {
            displayedShortcut = candidate
            isRecording = false
            window?.makeFirstResponder(nil)
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isRecording {
            isRecording = false
            onCancel?()
        }
        return resigned
    }

    override func accessibilityValue() -> Any? {
        isRecording ? "Recording" : displayedShortcut.displayName
    }

    private func updateTitle() {
        title = isRecording ? "Press a shortcut…" : displayedShortcut.displayName
    }
}
