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
    private var workspaceObserver: NSObjectProtocol?
    private var isHotKeyEditingAttemptInProgress = false
    private let hasSeenWelcomeKey = "hasSeenWelcome"

    init(config: AppConfig = AppConfigLoader.load(), automationService: FinderAutomationServing = FinderAutomationService()) {
        self.config = config
        self.automationService = automationService
        self.tracker = FinderWindowTracker(config: config, automationService: automationService)
        self.viewModel = PathBarViewModel(displayMode: config.displayMode, automationService: automationService)
        self.overlayController = OverlayWindowController(viewModel: viewModel)
    }

    func start() {
        showWelcomeIfNeeded()

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
            guard self.canBeginEditingFromHotKey else { return }
            self.beginEditingFromHotKey()
        }
        registerHotKey(config.shortcut)
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
                guard !self.shouldKeepOverlayVisible else { return }
                self.overlayController.hide()
            case .hidden:
                guard !self.shouldKeepOverlayVisible else { return }
                self.overlayController.hide()
            }
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

    private func showWelcomeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: hasSeenWelcomeKey) else { return }

        welcomeWindowController.show(
            onDismiss: { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(true, forKey: self.hasSeenWelcomeKey)
            }
        )
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
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmostBundleID == "com.apple.finder" {
            return true
        }

        return frontmostBundleID == Bundle.main.bundleIdentifier && overlayController.isVisible
    }

    private var shouldKeepOverlayVisible: Bool {
        isHotKeyEditingAttemptInProgress
            || (viewModel.isEditing && NSApp.isActive)
            || overlayController.shouldHoldVisibility
    }

    private func handleActivatedApplicationChange() {
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isFinderFrontmost = frontmostBundleID == "com.apple.finder"
        let isEditingHere = viewModel.isEditing && NSApp.isActive

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

        let registrationStatus = hotKeyManager.register(shortcut: updatedConfig.shortcut)
        guard registrationStatus == noErr else {
            registerHotKey(config.shortcut)
            return "Could not register keyboard shortcut: OSStatus \(registrationStatus)"
        }

        do {
            try AppConfigLoader.save(updatedConfig)
        } catch {
            registerHotKey(config.shortcut)
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

    private func registerHotKey(_ shortcut: AppConfig.Shortcut) {
        let status = hotKeyManager.register(shortcut: shortcut)
        if status != noErr {
            NSLog("FinderBreadcrumbs failed to register hotkey %@: OSStatus %d", shortcut.description, status)
        }
    }
}
