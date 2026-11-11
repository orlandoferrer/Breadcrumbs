import AppKit
import Carbon
import Foundation

@MainActor
/// The composition root: creates subsystems and defines how they communicate.
///
/// Keeping this wiring in one object lets the tracker, view model, and window
/// controller stay focused on their own responsibilities.
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
    private var hotKeyEditRequestGate = HotKeyEditRequestGate()
    private let hotKeyEditRequestTimeout: TimeInterval = 2.0
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
            return isActivelyEditingHere || self.overlayController.shouldHoldVisibility
        }

        // Tracker updates describe intent; the coordinator decides how UI state
        // and window visibility should change in response.
        tracker.onUpdate = { [weak self] update in
            guard let self else { return }
            switch update {
            case .snapshot(let snapshot):
                self.viewModel.update(state: snapshot.state, displayMode: self.config.displayMode)
                self.overlayController.update(with: snapshot, config: self.config)
            case .temporarilyHiddenForMotion:
                self.overlayController.hide()
            case .hiddenForQuickLook:
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
        hotKeyEditRequestGate.cancel()
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
        let requestID = hotKeyEditRequestGate.begin()
        logHotKeyEditing("request \(requestID) started")
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A newer press owns the pending tracker request; leave it alone.
            guard self.hotKeyEditRequestGate.cancel(requestID: requestID) else { return }
            self.tracker.cancelFreshSnapshotRequest()
            self.logHotKeyEditing("request \(requestID) timed out")
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + hotKeyEditRequestTimeout,
            execute: timeout
        )

        tracker.requestFreshSnapshot { [weak self] snapshot in
            timeout.cancel()
            guard let self else { return }
            let finderIsFrontmost = self.canBeginEditingFromHotKey
            let shouldBeginEditing = self.hotKeyEditRequestGate.consume(
                requestID: requestID,
                finderIsFrontmost: finderIsFrontmost,
                hasFreshSnapshot: snapshot != nil
            )
            guard shouldBeginEditing, let snapshot else {
                self.logHotKeyEditing(
                    "request \(requestID) ignored; frontmost=\(finderIsFrontmost) snapshot=\(snapshot != nil)"
                )
                return
            }

            self.logHotKeyEditing("request \(requestID) matched Finder window \(snapshot.state?.windowID ?? -1)")
            self.viewModel.update(state: snapshot.state, displayMode: self.config.displayMode)
            self.overlayController.update(with: snapshot, config: self.config)
            _ = self.overlayController.beginEditing()
        }
    }

    private func logHotKeyEditing(_ message: String) {
        guard config.debugLogFinderWindowDiagnostics else { return }
        NSLog("FinderBreadcrumbs hotkey edit: %@", message)
    }

    private var canBeginEditingFromHotKey: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundleIdentifier
    }

    private var shouldKeepOverlayVisible: Bool {
        (viewModel.isEditing && NSApp.isActive)
            || overlayController.shouldHoldVisibility
    }

    private func handleActivatedApplicationChange() {
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isFinderFrontmost = frontmostBundleID == finderBundleIdentifier
        let isEditingHere = viewModel.isEditing && NSApp.isActive

        syncHotKeyRegistration(frontmostBundleIdentifier: frontmostBundleID)

        if !isFinderFrontmost {
            hotKeyEditRequestGate.cancel()
            tracker.cancelFreshSnapshotRequest()
        }

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
        hotKeyEditRequestGate.cancel()
        tracker.cancelFreshSnapshotRequest()
        hotKeyManager.deactivate()
    }

    private func applySettings(_ draft: AppSettingsDraft) -> String? {
        let finderBundleIdentifier = finderBundleIdentifier
        let transaction = SettingsSaveTransaction(
            hotKeyManager: hotKeyManager,
            isFinderFrontmost: {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundleIdentifier
            },
            setLaunchAtLogin: { try LoginItemManager.setEnabled($0) },
            saveConfig: { try AppConfigLoader.save($0) }
        )
        let updatedConfig: AppConfig
        switch transaction.apply(draft, to: config, launchAtLoginWasEnabled: LoginItemManager.isEnabled) {
        case .saved(let savedConfig):
            updatedConfig = savedConfig
        case .rejected(let message):
            return message
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
}
