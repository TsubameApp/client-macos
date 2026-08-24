import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController {
    init(model: AppModel) {
        let hostingController = NSHostingController(
            rootView: ContentView(model: model)
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 700, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tsubame"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("TsubameMainWindow")
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func toggle() {
        if window?.isVisible == true {
            hide()
        } else {
            show()
        }
    }
}
