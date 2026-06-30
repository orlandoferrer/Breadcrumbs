import AppKit

@MainActor
final class StatusMenuController: NSObject {
    private let statusItem: NSStatusItem
    private let onOpenSettings: () -> Void

    init(onOpenSettings: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.onOpenSettings = onOpenSettings
        super.init()
        configureStatusItem()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "menubar.dock.rectangle",
                accessibilityDescription: "FinderBreadcrumbs"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Breadcrumbs", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
