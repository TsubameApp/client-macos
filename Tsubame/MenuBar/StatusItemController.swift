import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let toggleMainWindow: () -> Void
    private let showMainWindow: () -> Void
    private let statusItem: NSStatusItem
    private lazy var contextMenu = makeContextMenu()
    private weak var developerModeItem: NSMenuItem?

    init(
        model: AppModel,
        toggleMainWindow: @escaping () -> Void,
        showMainWindow: @escaping () -> Void
    ) {
        self.model = model
        self.toggleMainWindow = toggleMainWindow
        self.showMainWindow = showMainWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            image?.accessibilityDescription = "Tsubame"
            button.image = image
            button.toolTip = "Tsubame — \(model.globalShortcut.displayName)"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func updateShortcut(_ shortcut: Shortcut) {
        statusItem.button?.toolTip = "Tsubame — \(shortcut.displayName)"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = contextMenu
            developerModeItem?.state = model.developerModeEnabled ? .on : .off
            menu.popUp(
                positioning: nil,
                at: CGPoint(x: 0, y: sender.bounds.maxY + 4),
                in: sender
            )
        } else {
            toggleMainWindow()
        }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "Open Tsubame",
            action: #selector(openTsubame),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let developerItem = NSMenuItem(
            title: "Developer Mode",
            action: #selector(toggleDeveloperMode),
            keyEquivalent: ""
        )
        developerItem.target = self
        developerModeItem = developerItem
        menu.addItem(developerItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Tsubame",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func openTsubame() {
        showMainWindow()
    }

    @objc private func toggleDeveloperMode() {
        model.developerModeEnabled.toggle()
        developerModeItem?.state = model.developerModeEnabled ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
