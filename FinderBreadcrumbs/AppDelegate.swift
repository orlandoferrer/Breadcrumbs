import AppKit

/// Bridges macOS application lifecycle callbacks into the app's own objects.
///
/// These properties are retained for the process lifetime; without them, the
/// coordinator and status item would be deallocated after launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var statusMenuController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An accessory app has a menu-bar item but no Dock icon or app menu.
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
