import AppKit
import Foundation

@MainActor
final class AppCoordinator {
    private var config: AppConfig
    private let automationService: FinderAutomationServing
    private let tracker: FinderWindowTracker
    private let viewModel: PathBarViewModel
    private let overlayController: OverlayWindowController
    private let hotKeyManager = HotKeyManager()
    private let settingsWindowController = SettingsWindowController()
    private let permissionsOnboardingWindowController = PermissionsOnboardingWindowController()
    private var workspaceObserver: NSObjectProtocol?
    private var didDismissPermissionsOnboardingThisRun = false

    init(config: AppConfig = AppConfigLoader.load(), automationService: FinderAutomationServing = FinderAutomationService()) {
        self.config = config
        self.automationService = automationService
        self.tracker = FinderWindowTracker(config: config, automationService: automationService)
        self.viewModel = PathBarViewModel(displayMode: config.displayMode, automationService: automationService)
        self.overlayController = OverlayWindowController(viewModel: viewModel)
    }

    func start() {
        showPermissionsOnboardingIfNeeded()

        viewModel.onEditingEnded = { shouldReturnFocusToFinder in
            self.overlayController.endEditing()
            if shouldReturnFocusToFinder {
                NSRunningApplication
                    .runningApplications(withBundleIdentifier: "com.apple.finder")
                    .first?
                    .activate()
            }
        }

        hotKeyManager.onActivate = { [weak self] in
            guard let self else { return }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
            self.beginEditingFromHotKey()
        }
        hotKeyManager.register(shortcut: config.shortcut)
        tracker.shouldRemainVisible = { [weak self] in
            guard let self else { return false }
            let isActivelyEditingHere = self.viewModel.isEditing && NSApp.isActive
            return isActivelyEditingHere || self.overlayController.shouldHoldVisibility
        }

        tracker.onUpdate = { [weak self] snapshot in
            guard let self else { return }
            guard let snapshot else {
                self.overlayController.hide()
                return
            }

            self.viewModel.update(state: snapshot.state, displayMode: self.config.displayMode)
            self.overlayController.update(with: snapshot, config: self.config)
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleActivatedApplicationChange()
            }
        }
        tracker.start()
    }

    func stop() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        tracker.stop()
        hotKeyManager.unregister()
    }

    func showSettings() {
        let draft = AppSettingsDraft(
            launchAtLogin: LoginItemManager.isEnabled,
            shortcut: config.shortcut,
            displayMode: config.displayMode
        )

        settingsWindowController.show(
            draft: draft,
            onSave: { [weak self] draft in
                self?.applySettings(draft)
            },
            onCancel: {}
        )
    }

    private func showPermissionsOnboardingIfNeeded() {
        let status = permissionStatus()
        guard !status.isComplete, !didDismissPermissionsOnboardingThisRun else { return }

        permissionsOnboardingWindowController.show(
            status: status,
            onOpenAccessibility: {
                AccessibilityPermissionManager.ensurePrompted()
                Self.openAccessibilitySettings()
            },
            onAllowFinderAccess: { [weak self] in
                _ = self?.automationService.requestAutomationPermission()
            },
            onCheckAgain: { [weak self] in
                self?.permissionStatus() ?? PermissionStatus(accessibilityGranted: false, finderAccessGranted: false)
            },
            onDismiss: { [weak self] in
                self?.didDismissPermissionsOnboardingThisRun = true
            }
        )
    }

    private func permissionStatus() -> PermissionStatus {
        PermissionStatus(
            accessibilityGranted: AccessibilityPermissionManager.isTrusted,
            finderAccessGranted: automationService.hasAutomationPermission()
        )
    }

    private static func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]

        for rawURL in urls {
            guard let url = URL(string: rawURL),
                  NSWorkspace.shared.open(url) else {
                continue
            }
            return
        }
    }

    private func beginEditingFromHotKey() {
        tracker.refreshNow()
        if overlayController.beginEditing() {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
            self.tracker.refreshNow()
            _ = self.overlayController.beginEditing()
        }
    }

    private func handleActivatedApplicationChange() {
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isFinderFrontmost = frontmostBundleID == "com.apple.finder"
        let isEditingHere = viewModel.isEditing && NSApp.isActive

        if isFinderFrontmost {
            tracker.refreshNow()
            return
        }

        guard !isEditingHere else {
            return
        }

        overlayController.cancelEditingAndHide(returnFocusToFinder: false)
    }

    private func applySettings(_ draft: AppSettingsDraft) -> String? {
        do {
            try LoginItemManager.setEnabled(draft.launchAtLogin)
        } catch {
            return "Could not update Enable at login: \(error.localizedDescription)"
        }

        var updatedConfig = config
        updatedConfig.launchAtLogin = draft.launchAtLogin
        updatedConfig.shortcut = draft.shortcut
        updatedConfig.displayMode = draft.displayMode

        do {
            try AppConfigLoader.save(updatedConfig)
        } catch {
            return "Could not save settings: \(error.localizedDescription)"
        }

        config = updatedConfig
        hotKeyManager.register(shortcut: updatedConfig.shortcut)

        if let currentState = viewModel.currentState {
            viewModel.update(state: currentState, displayMode: updatedConfig.displayMode)
        } else {
            viewModel.displayMode = updatedConfig.displayMode
        }

        tracker.refreshNow()
        return nil
    }
}
