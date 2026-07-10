import AppKit
import Carbon
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
    private let welcomeWindowController = WelcomeWindowController()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isHotKeyEditingAttemptInProgress = false
    private let hasSeenWelcomeKey = "hasSeenWelcome"
    private let finderBundleIdentifier = "com.apple.finder"

    init(
        config: AppConfig = AppConfigLoader.load(),
        automationService: FinderAutomationServing = FinderAutomationService(),
        trackingAutomationService: FinderAutomationServing = FinderAutomationService()
    ) {
        self.config = config
        self.automationService = automationService
        self.tracker = FinderWindowTracker(config: config, automationService: trackingAutomationService)
        self.viewModel = PathBarViewModel(displayMode: config.displayMode, automationService: automationService)
        self.overlayController = OverlayWindowController(viewModel: viewModel)
    }

    func start() {
        showWelcomeIfNeeded()

        viewModel.onEditingEnded = { [weak self] shouldReturnFocusToFinder in
            guard let self else { return }
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
            guard self.canBeginEditingFromHotKey else { return }
            self.beginEditingFromHotKey()
        }
        tracker.shouldRemainVisible = { [weak self] in
            guard let self else { return false }
            let isActivelyEditingHere = self.viewModel.isEditing && NSApp.isActive
            return self.isHotKeyEditingAttemptInProgress || isActivelyEditingHere || self.overlayController.shouldHoldVisibility
        }

        tracker.onUpdate = { [weak self] update in
            guard let self else { return }
            switch update {
            case .snapshot(let snapshot):
                self.viewModel.update(state: snapshot.state, displayMode: self.config.displayMode)
                self.overlayController.update(with: snapshot, config: self.config)
            case .temporarilyHiddenForMotion:
                self.overlayController.hide()
            case .hidden:
                guard !self.shouldKeepOverlayVisible else { return }
                self.overlayController.hide()
            }
        }

        let activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleActivatedApplicationChange()
            }
        }
        workspaceObservers.append(activationObserver)

        let deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleIdentifier = (
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            )?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.handleDeactivatedApplicationChange(bundleIdentifier: bundleIdentifier)
            }
        }
        workspaceObservers.append(deactivationObserver)

        syncHotKeyRegistration()
        tracker.start()
    }

    func stop() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
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

    func showWelcome() {
        welcomeWindowController.show(
            onDismiss: { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(true, forKey: self.hasSeenWelcomeKey)
            }
        )
    }

    private func showWelcomeIfNeeded() {
        let hasSeenWelcome = UserDefaults.standard.bool(forKey: hasSeenWelcomeKey)
        guard !hasSeenWelcome || !arePermissionsGranted else { return }
        showWelcome()
    }

    private var arePermissionsGranted: Bool {
        guard AccessibilityPermissionManager.isTrusted else { return false }

        switch AutomationPermissionManager.finderAutomationState() {
        case .granted, .unknown:
            return true
        case .denied, .notDetermined:
            return false
        }
    }

    private func beginEditingFromHotKey() {
        isHotKeyEditingAttemptInProgress = true
        tracker.refreshNow()
        if overlayController.beginEditing() {
            isHotKeyEditingAttemptInProgress = false
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer {
                self.isHotKeyEditingAttemptInProgress = false
            }
            guard self.canBeginEditingFromHotKey else { return }
            self.tracker.refreshNow()
            _ = self.overlayController.beginEditing()
        }
    }

    private var canBeginEditingFromHotKey: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundleIdentifier
    }

    private var shouldKeepOverlayVisible: Bool {
        isHotKeyEditingAttemptInProgress
            || (viewModel.isEditing && NSApp.isActive)
            || overlayController.shouldHoldVisibility
    }

    private func handleActivatedApplicationChange() {
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isFinderFrontmost = frontmostBundleID == finderBundleIdentifier
        let isEditingHere = viewModel.isEditing && NSApp.isActive

        syncHotKeyRegistration(frontmostBundleIdentifier: frontmostBundleID)

        if isFinderFrontmost {
            tracker.refreshNow()
            return
        }

        if frontmostBundleID == Bundle.main.bundleIdentifier {
            return
        }

        guard !isEditingHere else {
            return
        }

        overlayController.cancelEditingAndHide(returnFocusToFinder: false)
    }

    private func handleDeactivatedApplicationChange(bundleIdentifier: String?) {
        guard bundleIdentifier == finderBundleIdentifier else { return }
        hotKeyManager.deactivate()
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

        let finderIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundleIdentifier
        if finderIsFrontmost {
            let registrationStatus = hotKeyManager.register(shortcut: updatedConfig.shortcut)
            guard registrationStatus == noErr else {
                registerHotKey(config.shortcut)
                return "Could not register keyboard shortcut: OSStatus \(registrationStatus)"
            }
        }

        do {
            try AppConfigLoader.save(updatedConfig)
        } catch {
            if finderIsFrontmost {
                registerHotKey(config.shortcut)
            }
            return "Could not save settings: \(error.localizedDescription)"
        }

        config = updatedConfig

        if let currentState = viewModel.currentState {
            viewModel.update(state: currentState, displayMode: updatedConfig.displayMode)
        } else {
            viewModel.displayMode = updatedConfig.displayMode
        }

        tracker.refreshNow()
        return nil
    }

    private func syncHotKeyRegistration(frontmostBundleIdentifier: String? = nil) {
        let bundleIdentifier = frontmostBundleIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let status = hotKeyManager.setRegistrationEnabled(
            bundleIdentifier == finderBundleIdentifier,
            shortcut: config.shortcut
        )
        if status != noErr {
            NSLog("FinderBreadcrumbs failed to register hotkey %@: OSStatus %d", config.shortcut.description, status)
        }
    }

    private func registerHotKey(_ shortcut: AppConfig.Shortcut) {
        let status = hotKeyManager.register(shortcut: shortcut)
        if status != noErr {
            NSLog("FinderBreadcrumbs failed to register hotkey %@: OSStatus %d", shortcut.description, status)
        }
    }
}
