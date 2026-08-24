import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var mainWindowController: MainWindowController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let mainWindowController = MainWindowController(model: model)
        self.mainWindowController = mainWindowController
        statusItemController = StatusItemController(
            model: model,
            toggleMainWindow: { [weak mainWindowController] in
                mainWindowController?.toggle()
            },
            showMainWindow: { [weak mainWindowController] in
                mainWindowController?.show()
            }
        )

        model.onOnboardingCompleted = { [weak mainWindowController] in
            mainWindowController?.hide()
        }
        model.onMainWindowRequired = { [weak mainWindowController] in
            mainWindowController?.show()
        }
        model.start()

        if model.shouldShowMainWindowOnLaunch {
            mainWindowController.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        mainWindowController?.show()
        return true
    }
}
