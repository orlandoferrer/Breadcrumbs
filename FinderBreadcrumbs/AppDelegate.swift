import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var statusMenuController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator = AppCoordinator()
        coordinator?.start()
        statusMenuController = StatusMenuController(
            onOpenSettings: { [weak self] in
                self?.coordinator?.showSettings()
            },
            onShowWelcome: { [weak self] in
                self?.coordinator?.showWelcome()
            }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
