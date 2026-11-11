import AppKit
import Carbon
import Foundation

@main
/// Lightweight regression runner used by `check.sh`.
///
/// These are intentionally dependency-free executable tests rather than an
/// XCTest target. A failed expectation prints its reason and exits nonzero.
struct EditingFocusRegressionTests {
    static func main() async {
        await MainActor.run {
            testOutsideClickCancelDoesNotReturnFocusToFinder()
            testCommitStillReturnsFocusToFinder()
            testEditingInitialCursorPlacementDefaultsToEnd()
            testBeginEditingRequiresCurrentState()
            testBeginEditingIncrementsFocusSession()
            testStateChangeEndsEditingWithoutReturningFocus()
            testTransientFinderReadPreservesEditing()
            testExpiredFinderStateClearsPathAndDisablesEditing()
            testCommitUsesWindowWhereEditSessionBegan()
            testCommitPinsNavigationToEditingWindow()
            testShortcutRecorderIgnoresUnfocusedKeyEquivalents()
            testShortcutRecorderCapturesOnlyOneFocusedCombination()
            testShortcutRecorderStopsAfterLosingFocus()
            testShortcutRecorderIgnoresCommandsInBackgroundWindow()
            testShortcutRecorderInitialFocusDoesNotRecord()
            testShortcutRecorderEscapeCancelsWithoutChangingShortcut()
            testShortcutRecorderTabMovesFocusWithoutRecording()
            testShortcutRecorderReturnReachesDefaultAction()
            testShortcutRecorderStopsWhenWindowResignsKey()
            testShortcutRecorderRejectsTextInputCombination()
            testSettingsSaveRejectsTextInputShortcutBeforeSideEffects()
            testSettingsSaveConflictPreservesOldShortcutAndLoginItem()
            testSettingsSaveReleasesValidatedShortcutWhileFinderInactive()
            testSettingsSaveRollsBackLoginItemWhenConfigWriteFails()
            testSettingsSaveRejectsFinalRegistrationFailure()
            testSettingsSaveReportsFailedLoginRollback()
            testSettingsSaveReportsFailedConfigRollback()
            testSettingsSaveReportsFailedHotKeyRestore()
            testTrackerActivationAfterInactivityWaitsForFreshRead()
            testTrackerSlowReadKeepsVisiblePathOnlyBriefly()
            testTrackerFailedReadExpiresDespitePendingRetry()
            testTrackerWindowSwitchNeverPairsAnotherWindowsPath()
            testTrackerRejectsPreHotKeyReadFromSameWindow()
            testTrackerHotKeyRejectsReadDiscardedAfterWindowSwitch()
            testTrackerHotKeyChecksWindowFreshnessAfterPolling()
            testTrackerCoalescesHotKeyPressesAndForcedRefreshes()
            testTrackerHotKeyRequestCancellationRejectsLateReads()
        }
        testReadableShortcutDecoding()
        testLegacyShortcutDecoding()
        testReadableShortcutEncoding()
        testShortcutValidationPolicy()
        testConfigMissingDiagnosticsFlagUsesDefault()
        testConfigIgnoresRemovedTrackingFlag()
        testConfigSanitizesInvalidPollingIntervals()
        testConfigTextInputShortcutFallsBackAlone()
        testConfigUnreadableShortcutFallsBackAlone()
        testConfigPreservesValidShortcuts()
        testFinderStateAcceptsFileURLFallback()
        testFinderStateRecoversClassCodedAFPPath()
        testFinderStateScriptProtectsDescriptionCoercion()
        testNavigationAcceptsNonTextAppleScriptResult()
        testNavigationScriptCannotRetargetAnotherWindow()
        testMissingNavigationWindowFailsWithoutRetry()
        testUntargetedNavigationStillAllowsOpeningAWindow()
        testFinderStateRefreshCacheThrottlesMotionPolling()
        testFinderReadFailuresCannotRenewOldPaths()
        testFinderSlowReadGraceIsBoundedAndRecovers()
        testFinderCacheNeverUsesAnotherWindowsPath()
        testFinderCacheRejectsReadsStartedBeforeActivation()
        testFinderPollReentrancyIsCoalesced()
        testFreshSnapshotRequestsCoalesceAndRetryOnce()
        testFreshFinderWindowPairingRequiresMatchingWindowID()
        testHotKeyEditRequestRejectsStaleAndCancelledResults()
        testLiveResizeBypassesPollSuppression()
        testMotionHidingWaitsForMouseRelease()
        testFinderResizeBorderHitTesting()
        testQuickLookAXWindowDetection()
        testDragToInstallVolumeDetection()
        testHotKeyRegistrationReturnsRegisterFailure()
        testHotKeyRegistrationReturnsHandlerFailureAndCleansUp()
        testHotKeyRegistrationSuccessInstallsHandler()
        testInactiveHotKeyDoesNotRegister()
        testRepeatedFinderActivationIsIdempotent()
        testFinderDeactivationReleasesOnlyHotKey()
        testReturningToFinderReusesInstalledHandler()
    }

    @MainActor
    private static func testOutsideClickCancelDoesNotReturnFocusToFinder() {
        let viewModel = makeReadyViewModel()
        var returnFocusRequests: [Bool] = []
        viewModel.onEditingEnded = { shouldReturnFocusToFinder in
            returnFocusRequests.append(shouldReturnFocusToFinder)
        }

        expect(viewModel.beginEditing(), "Expected editing to begin with a current Finder state.")
        viewModel.cancelEditing(returnFocusToFinder: false)

        expect(
            returnFocusRequests == [false],
            "Clicking away must not reactivate Finder; that keeps the overlay floating over other apps."
        )
    }

    @MainActor
    private static func testCommitStillReturnsFocusToFinder() {
        let viewModel = makeReadyViewModel()
        var returnFocusRequests: [Bool] = []
        viewModel.onEditingEnded = { shouldReturnFocusToFinder in
            returnFocusRequests.append(shouldReturnFocusToFinder)
        }

        expect(viewModel.beginEditing(), "Expected editing to begin with a current Finder state.")
        viewModel.editingText = "/tmp"
        viewModel.commitEditing()

        expect(
            returnFocusRequests == [true],
            "Committing an edit should still return focus to Finder."
        )
    }

    @MainActor
    private static func testEditingInitialCursorPlacementDefaultsToEnd() {
        let field = KeyAwareTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = "/Users/orlando/Documents/BreadCrumbs"
        let insertionIndex = EditingCursorPlacement.endInsertionIndex(for: field)

        expect(
            insertionIndex == field.stringValue.count,
            "Edit mode should place the caret at the end of the path string."
        )
    }

    @MainActor
    private static func testBeginEditingRequiresCurrentState() {
        let viewModel = PathBarViewModel(
            displayMode: .text,
            automationService: MockFinderAutomationService()
        )

        expect(!viewModel.beginEditing(), "Editing should not begin before Finder state is known.")
        expect(!viewModel.isEditing, "Failed edit attempts must not leave the view model editing.")
    }

    @MainActor
    private static func testBeginEditingIncrementsFocusSession() {
        let viewModel = makeReadyViewModel()
        let initialSessionID = viewModel.editingSessionID

        expect(viewModel.beginEditing(), "Expected editing to begin with a current Finder state.")
        expect(
            viewModel.editingSessionID == initialSessionID + 1,
            "Starting an edit session should advance the focus request token exactly once."
        )
        expect(viewModel.editingWindowID == 1, "Editing should remember the Finder window it started from.")
    }

    @MainActor
    private static func testStateChangeEndsEditingWithoutReturningFocus() {
        let viewModel = makeReadyViewModel()
        var returnFocusRequests: [Bool] = []
        viewModel.onEditingEnded = { shouldReturnFocusToFinder in
            returnFocusRequests.append(shouldReturnFocusToFinder)
        }

        expect(viewModel.beginEditing(), "Expected editing to begin with a current Finder state.")
        viewModel.editingText = "/tmp/manual"
        viewModel.update(
            state: FinderState(
                displayedPath: "/private/tmp",
                resolvedPath: "/private/tmp",
                windowID: 1
            ),
            displayMode: .text
        )

        expect(!viewModel.isEditing, "Finder target changes should end an active edit session.")
        expect(viewModel.displayedText == "/private/tmp", "The bar should refresh to the new Finder target after editing ends.")
        expect(viewModel.editingText == "/private/tmp", "The edit buffer should reset to the latest Finder path after editing ends.")
        expect(viewModel.editingWindowID == nil, "Ending an edit session should clear the pinned Finder window.")
        expect(returnFocusRequests == [false], "Tracker-driven edit cancellation must not steal focus back to Finder.")
    }

    @MainActor
    private static func testTransientFinderReadPreservesEditing() {
        let viewModel = makeReadyViewModel()
        var cache = FinderStateRefreshCache()
        let initialDate = Date(timeIntervalSinceReferenceDate: 1_000)
        recordRead(&cache, viewModel.currentState, at: initialDate)
        var returnFocusRequests: [Bool] = []
        viewModel.onEditingEnded = { shouldReturnFocusToFinder in
            returnFocusRequests.append(shouldReturnFocusToFinder)
        }

        expect(viewModel.beginEditing(), "Expected editing to begin with a current Finder state.")
        viewModel.editingText = "/tmp/manual"
        let failureDate = initialDate.addingTimeInterval(0.125)
        recordRead(&cache, nil, at: failureDate)
        let lookup = cache.lookup(windowNumber: 1, now: failureDate, maximumAge: 0.25, pendingReadGrace: 1.5, isShowingPath: true)
        expect(lookup == .current(viewModel.currentState!), "A short Finder read interruption should retain a matching path.")
        viewModel.update(state: viewModel.currentState, displayMode: .text)

        expect(viewModel.isEditing, "Transient unavailable tracking updates must not cancel an active edit session.")
        expect(viewModel.editingText == "/tmp/manual", "Unavailable updates must not overwrite in-progress edits.")
        expect(returnFocusRequests.isEmpty, "Unavailable updates should not fire editing cleanup callbacks.")
    }

    @MainActor
    private static func testExpiredFinderStateClearsPathAndDisablesEditing() {
        let service = RecordingFinderAutomationService()
        let viewModel = PathBarViewModel(displayMode: .text, automationService: service)
        let initialDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let state = FinderState(displayedPath: "/tmp", resolvedPath: "/tmp", windowID: 42)
        var cache = FinderStateRefreshCache()
        recordRead(&cache, state, at: initialDate)
        viewModel.update(state: state, displayMode: .text)
        expect(viewModel.beginEditing(), "A known Finder path should permit editing.")
        viewModel.editingText = "/Users"
        var returnFocusRequests: [Bool] = []
        viewModel.onEditingEnded = { returnFocusRequests.append($0) }

        let expiredDate = initialDate.addingTimeInterval(0.25)
        recordRead(&cache, nil, at: expiredDate)
        let lookup = cache.lookup(windowNumber: 42, now: expiredDate, maximumAge: 0.25, pendingReadGrace: 1.5, isShowingPath: true)
        expect(lookup == .unavailable, "An expired path after a failed read must become unavailable for its window.")
        viewModel.update(state: nil, displayMode: .text)

        expect(viewModel.currentState == nil, "Expiry must remove the old navigation target.")
        expect(!viewModel.isEditing && viewModel.editingWindowID == nil, "Expiry must cancel and unpin editing.")
        expect(viewModel.editingText.isEmpty, "Expiry must clear the old edit buffer.")
        expect(viewModel.displayedText == "Finder location unavailable", "An old path must be replaced with an unavailable message.")
        expect(!viewModel.beginEditing(), "Clicking an unavailable path must not restart editing.")
        viewModel.commitEditing()
        expect(service.navigateRequests.isEmpty, "An expired edit must never send a navigation request.")
        viewModel.update(state: nil, displayMode: .text)
        expect(returnFocusRequests == [false], "Expiry should end editing once without activating Finder.")

        let recovered = FinderState(displayedPath: "/Users", resolvedPath: "/Users", windowID: 42)
        recordRead(&cache, recovered, at: expiredDate)
        let recoveredLookup = cache.lookup(windowNumber: 42, now: expiredDate, maximumAge: 0.25, pendingReadGrace: 1.5, isShowingPath: false)
        expect(recoveredLookup == .current(recovered), "A successful read must restore a current path.")
        viewModel.update(state: recovered, displayMode: .text)
        expect(viewModel.displayedText == "/Users", "A successful read should replace the unavailable message.")
        expect(viewModel.beginEditing(), "Fresh state should restore editing.")
        expect(viewModel.editingWindowID == 42 && viewModel.editingText == "/Users", "Recovery must use the fresh path and its window.")
    }

    @MainActor
    private static func testCommitPinsNavigationToEditingWindow() {
        let service = RecordingFinderAutomationService()
        let viewModel = PathBarViewModel(displayMode: .text, automationService: service)
        viewModel.update(
            state: FinderState(displayedPath: "/Users", resolvedPath: "/Users", windowID: 42),
            displayMode: .text
        )
        expect(viewModel.beginEditing(), "Expected a pinned edit session.")
        viewModel.editingText = NSTemporaryDirectory()
        viewModel.commitEditing()
        expect(service.navigateRequests.count == 1, "Return should send exactly one navigation request.")
        expect(service.navigateRequests.first?.windowID == 42, "Navigation must retain the edit session's window ID.")
    }

    @MainActor
    private static func testShortcutRecorderIgnoresUnfocusedKeyEquivalents() {
        let (window, recorder) = makeShortcutRecorderWindow()
        var recorded: [AppConfig.Shortcut] = []
        recorder.onShortcut = { recorded.append($0) }
        let event = shortcutEvent(in: window, keyCode: kVK_ANSI_X, characters: "x", modifiers: .command)

        expect(window.firstResponder !== recorder, "The recorder must start unfocused.")
        expect(!window.contentView!.performKeyEquivalent(with: event), "An unfocused recorder must not consume another control's command.")
        expect(recorded.isEmpty, "Command-X outside the recorder must not overwrite the shortcut.")
    }

    @MainActor
    private static func testShortcutRecorderCapturesOnlyOneFocusedCombination() {
        let (window, recorder) = makeShortcutRecorderWindow()
        var recorded: [AppConfig.Shortcut] = []
        recorder.onShortcut = { recorded.append($0) }
        click(recorder)
        expect(window.firstResponder === recorder, "A single click should focus the recorder.")
        let event = shortcutEvent(in: window, keyCode: kVK_ANSI_L, characters: "l", modifiers: [.command, .option])

        expect(window.contentView!.performKeyEquivalent(with: event), "A focused recorder must consume the requested combination.")
        expect(recorded == [AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey))], "Record the actual key and modifiers.")
        expect(window.firstResponder !== recorder, "Recording one combination should release focus.")
        expect(!window.contentView!.performKeyEquivalent(with: event), "Later combinations must pass through after recording finishes.")
        expect(recorded.count == 1, "One recording session must capture only one combination.")

        click(recorder)
        recorder.keyDown(with: event)
        expect(recorded.count == 2, "Focused keyDown delivery must also support recording.")
    }

    @MainActor
    private static func testShortcutRecorderStopsAfterLosingFocus() {
        let (window, recorder) = makeShortcutRecorderWindow()
        var recorded: [AppConfig.Shortcut] = []
        recorder.onShortcut = { recorded.append($0) }
        click(recorder)
        expect(window.makeFirstResponder(window), "Another responder should be able to take focus.")
        let event = shortcutEvent(in: window, keyCode: kVK_ANSI_X, characters: "x", modifiers: .command)

        expect(!window.contentView!.performKeyEquivalent(with: event), "Losing focus must stop consuming commands.")
        expect(recorded.isEmpty, "An abandoned recording session must not change the shortcut.")
    }

    @MainActor
    private static func testShortcutRecorderIgnoresCommandsInBackgroundWindow() {
        let (window, recorder) = makeShortcutRecorderWindow()
        var recorded: [AppConfig.Shortcut] = []
        recorder.onShortcut = { recorded.append($0) }
        click(recorder)
        window.reportsKeyWindow = false
        expect(window.firstResponder === recorder, "A background window may retain its first responder.")
        let event = shortcutEvent(in: window, keyCode: kVK_ANSI_X, characters: "x", modifiers: .command)
        expect(!window.contentView!.performKeyEquivalent(with: event), "A background Settings window must not capture commands.")
        expect(recorded.isEmpty, "Switching windows must prevent shortcut changes in the inactive recorder.")
    }

    @MainActor
    private static func testShortcutRecorderInitialFocusDoesNotRecord() {
        let (window, recorder) = makeShortcutRecorderWindow()
        var recorded: [AppConfig.Shortcut] = []
        recorder.onShortcut = { recorded.append($0) }
        recorder.shortcutDescription = "cmd+l"

        // Settings may assign initial focus to the recorder when it opens.
        expect(window.makeFirstResponder(recorder), "The recorder should accept initial focus.")
        let command = shortcutEvent(in: window, keyCode: kVK_ANSI_X, characters: "x", modifiers: .command)
        expect(!window.contentView!.performKeyEquivalent(with: command), "Initial focus alone must not start recording.")
        expect(recorded.isEmpty, "Opening Settings must not capture a shortcut.")

        recorder.keyDown(with: shortcutEvent(in: window, keyCode: kVK_Space, characters: " ", modifiers: []))
        let shortcut = shortcutEvent(in: window, keyCode: kVK_ANSI_K, characters: "k", modifiers: .control)
        expect(window.contentView!.performKeyEquivalent(with: shortcut), "Space should start recording from the keyboard.")
        expect(recorded == [AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey))], "Keyboard-started recording should capture one combination.")
    }

    @MainActor
    private static func testShortcutRecorderEscapeCancelsWithoutChangingShortcut() {
        let (window, recorder) = makeShortcutRecorderWindow()
        var recorded: [AppConfig.Shortcut] = []
        recorder.onShortcut = { recorded.append($0) }
        recorder.shortcutDescription = "cmd+l"
        let escape = shortcutEvent(in: window, keyCode: kVK_Escape, characters: "\u{1b}", modifiers: [])
        let command = shortcutEvent(in: window, keyCode: kVK_ANSI_X, characters: "x", modifiers: .command)

        click(recorder)
        recorder.keyDown(with: escape)
        expect(!window.contentView!.performKeyEquivalent(with: command), "Escape must end the recording session.")

        click(recorder)
        expect(window.contentView!.performKeyEquivalent(with: escape), "Escape should cancel recording rather than the Settings window.")
        expect(!window.contentView!.performKeyEquivalent(with: command), "Escape as a key equivalent must also end recording.")
        expect(recorded.isEmpty, "Escape must not change the shortcut.")
        expect(recorder.shortcutDescription == "cmd+l", "Escape must keep the previous shortcut visible.")
    }

    @MainActor
    private static func testShortcutRecorderTabMovesFocusWithoutRecording() {
        let (window, recorder) = makeShortcutRecorderWindow()
        var recorded: [AppConfig.Shortcut] = []
        recorder.onShortcut = { recorded.append($0) }
        let previous = FocusProbeView(frame: NSRect(x: 200, y: 10, width: 20, height: 20))
        let next = FocusProbeView(frame: NSRect(x: 230, y: 10, width: 20, height: 20))
        window.contentView!.addSubview(previous)
        window.contentView!.addSubview(next)
        previous.nextKeyView = recorder
        recorder.nextKeyView = next

        click(recorder)
        let tab = shortcutEvent(in: window, keyCode: kVK_Tab, characters: "\t", modifiers: [])
        expect(!window.contentView!.performKeyEquivalent(with: tab), "Tab must not be consumed as a key equivalent.")
        recorder.keyDown(with: tab)
        expect(window.firstResponder === next, "Tab should move focus to the next control.")

        click(recorder)
        recorder.keyDown(with: shortcutEvent(in: window, keyCode: kVK_Tab, characters: "\u{19}", modifiers: .shift))
        expect(window.firstResponder === previous, "Shift-Tab should move focus to the previous control.")
        expect(recorded.isEmpty, "Focus traversal must not record Tab as the shortcut.")
    }

    @MainActor
    private static func testShortcutRecorderReturnReachesDefaultAction() {
        let (window, recorder) = makeShortcutRecorderWindow()
        var recorded: [AppConfig.Shortcut] = []
        var rejected = 0
        recorder.onShortcut = { recorded.append($0) }
        recorder.onRejectedShortcut = { rejected += 1 }
        let saveTarget = ActionProbe()
        let saveButton = NSButton(title: "Save", target: saveTarget, action: #selector(ActionProbe.recordAction(_:)))
        saveButton.frame = NSRect(x: 200, y: 50, width: 80, height: 28)
        saveButton.keyEquivalent = "\r"
        window.contentView!.addSubview(saveButton)
        let returnKey = shortcutEvent(in: window, keyCode: kVK_Return, characters: "\r", modifiers: [])

        click(recorder)
        expect(window.contentView!.performKeyEquivalent(with: returnKey), "Return should reach the default Save button.")
        expect(saveTarget.count == 1, "Return must trigger the default action while recording.")

        click(recorder)
        let chain = KeyDownProbe()
        recorder.nextResponder = chain
        recorder.keyDown(with: returnKey)
        expect(chain.keyCodes == [UInt16(kVK_Return)], "Return delivered as keyDown must continue up the responder chain.")
        expect(recorded.isEmpty, "Return must not be recorded as the shortcut.")
        expect(rejected == 0, "Return must not be rejected with an alert sound.")
    }

    @MainActor
    private static func testShortcutRecorderStopsWhenWindowResignsKey() {
        let (window, recorder) = makeShortcutRecorderWindow()
        var recorded: [AppConfig.Shortcut] = []
        recorder.onShortcut = { recorded.append($0) }
        click(recorder)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        expect(window.firstResponder === recorder, "The recorder may keep focus while its window is inactive.")
        let command = shortcutEvent(in: window, keyCode: kVK_ANSI_X, characters: "x", modifiers: .command)
        expect(!window.contentView!.performKeyEquivalent(with: command), "Returning to the window must not resume an abandoned recording.")
        expect(recorded.isEmpty, "Window deactivation must cancel recording.")

        click(recorder)
        expect(window.contentView!.performKeyEquivalent(with: command), "A new click should start recording again.")
        expect(recorded.count == 1, "Single-click recording must keep working after deactivation.")
    }

    @MainActor
    private static func testShortcutRecorderRejectsTextInputCombination() {
        let (window, recorder) = makeShortcutRecorderWindow()
        var recorded: [AppConfig.Shortcut] = []
        var rejected = 0
        recorder.onShortcut = { recorded.append($0) }
        recorder.onRejectedShortcut = { rejected += 1 }
        click(recorder)

        let shiftA = shortcutEvent(in: window, keyCode: kVK_ANSI_A, characters: "A", modifiers: .shift)
        expect(window.contentView!.performKeyEquivalent(with: shiftA), "A rejected combination is still consumed while recording.")
        expect(recorded.isEmpty, "Shift-A types text in Finder and must not be recorded.")
        expect(rejected == 1, "A rejected combination should produce feedback.")
        let commandK = shortcutEvent(in: window, keyCode: kVK_ANSI_K, characters: "k", modifiers: .command)
        expect(window.contentView!.performKeyEquivalent(with: commandK), "Recording should continue after a rejected combination.")
        expect(recorded == [AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey))], "A valid retry should be recorded.")
    }

    @MainActor
    private static func testSettingsSaveRejectsTextInputShortcutBeforeSideEffects() {
        let harness = SettingsSaveHarness(finderIsFrontmost: false)
        let shiftA = AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey))
        let outcome = harness.save(shortcut: shiftA, launchAtLogin: true)

        expect(outcome.rejectionMessage?.contains("not allowed") == true, "Settings must explain why Shift-A is rejected.")
        expect(harness.registrar.registerCalls == 0, "An invalid shortcut must never be registered.")
        expect(harness.loginChanges.isEmpty, "An invalid shortcut must not change Enable at login.")
        expect(harness.savedConfigs.isEmpty, "An invalid shortcut must not be saved.")
    }

    @MainActor
    private static func testSettingsSaveConflictPreservesOldShortcutAndLoginItem() {
        let commandK = AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey))

        let inactive = SettingsSaveHarness(finderIsFrontmost: false, rejectedKeyCodes: [commandK.keyCode])
        let inactiveOutcome = inactive.save(shortcut: commandK, launchAtLogin: true)
        expect(inactiveOutcome.rejectionMessage?.contains("Could not register") == true, "A conflict must be reported in Settings.")
        expect(inactive.registrar.registerCalls == 1, "Save must test registration even while Breadcrumbs is frontmost.")
        expect(inactive.loginChanges.isEmpty, "A conflicting shortcut must not change Enable at login.")
        expect(inactive.savedConfigs.isEmpty, "A conflicting shortcut must not be saved.")
        expect(inactive.registrar.activeKeyCodes.isEmpty, "No shortcut may stay reserved while Finder is inactive.")

        let active = SettingsSaveHarness(finderIsFrontmost: true, rejectedKeyCodes: [commandK.keyCode])
        active.manager.setRegistrationEnabled(true, shortcut: .default)
        let activeOutcome = active.save(shortcut: commandK, launchAtLogin: true)
        expect(activeOutcome.rejectionMessage != nil, "A conflict must be rejected while Finder is frontmost too.")
        expect(active.registrar.activeKeyCodes == [AppConfig.Shortcut.default.keyCode], "The old working shortcut must be restored for Finder.")
        expect(active.loginChanges.isEmpty, "A conflict must not change Enable at login.")
        expect(active.savedConfigs.isEmpty, "A conflict must not be saved.")
    }

    @MainActor
    private static func testSettingsSaveReleasesValidatedShortcutWhileFinderInactive() {
        let commandK = AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey))

        let inactive = SettingsSaveHarness(finderIsFrontmost: false)
        let outcome = inactive.save(shortcut: commandK, launchAtLogin: true)
        expect(outcome.savedShortcut == commandK, "A valid available shortcut should be saved.")
        expect(inactive.registrar.registerCalls == 1, "Save must validate registration even while Breadcrumbs is frontmost.")
        expect(inactive.registrar.activeKeyCodes.isEmpty, "The validation registration must be released immediately.")
        expect(inactive.loginChanges == [true], "Enable at login should change after the shortcut is validated.")
        expect(inactive.savedConfigs.map { $0.shortcut } == [commandK], "The validated shortcut should be written once.")

        let active = SettingsSaveHarness(finderIsFrontmost: true)
        active.manager.setRegistrationEnabled(true, shortcut: .default)
        _ = active.save(shortcut: commandK, launchAtLogin: false)
        expect(active.registrar.activeKeyCodes == [commandK.keyCode], "Finder should own only the new shortcut after saving.")
        expect(active.loginChanges.isEmpty, "An unchanged login setting should not be reapplied.")
    }

    @MainActor
    private static func testSettingsSaveRollsBackLoginItemWhenConfigWriteFails() {
        let harness = SettingsSaveHarness(finderIsFrontmost: false, failsToSave: true)
        let commandK = AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey))
        let outcome = harness.save(shortcut: commandK, launchAtLogin: true)

        expect(outcome.rejectionMessage?.contains("Could not save settings") == true, "A write failure must be reported.")
        expect(harness.loginChanges == [true, false], "A failed write should restore Enable at login.")
        expect(harness.registrar.activeKeyCodes.isEmpty, "A failed write must not leave a shortcut reserved.")
    }

    @MainActor
    private static func testSettingsSaveRejectsFinalRegistrationFailure() {
        let harness = SettingsSaveHarness(finderIsFrontmost: true)
        let commandK = AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey))
        harness.registrar.registrationStatusesByKey[commandK.keyCode] = [noErr, OSStatus(eventHotKeyExistsErr)]
        harness.manager.setRegistrationEnabled(true, shortcut: .default)

        let outcome = harness.save(shortcut: commandK, launchAtLogin: true)

        expect(outcome.rejectionMessage?.contains("Could not register") == true, "A conflict after the probe must reject Save.")
        expect(outcome.savedShortcut == nil, "Save must not report success without the requested hotkey.")
        expect(harness.savedConfigs.map { $0.shortcut } == [commandK, .default], "A late conflict must restore the previous config on disk.")
        expect(harness.registrar.activeKeyCodes == [AppConfig.Shortcut.default.keyCode], "A late conflict must restore the old working hotkey.")
        expect(harness.loginChanges == [true, false] && !harness.loginIsEnabled, "A late conflict must undo the login change.")
    }

    @MainActor
    private static func testSettingsSaveReportsFailedLoginRollback() {
        let harness = SettingsSaveHarness(finderIsFrontmost: false, failsToSave: true, failsToRestoreLogin: true)
        let outcome = harness.save(shortcut: .default, launchAtLogin: true)

        expect(outcome.rejectionMessage?.contains("Could not save settings") == true, "The original persistence failure must remain visible.")
        expect(outcome.rejectionMessage?.contains("Could not restore Enable at login") == true, "A failed rollback must not be swallowed.")
        expect(harness.loginIsEnabled, "The fixture must reproduce the login item remaining enabled.")
        expect(harness.loginChanges == [true, false], "Recovery should attempt to restore the old login setting once.")
        expect(harness.registrar.activeKeyCodes.isEmpty, "Even a partial rollback must release hotkeys outside Finder.")
    }

    @MainActor
    private static func testSettingsSaveReportsFailedConfigRollback() {
        let harness = SettingsSaveHarness(finderIsFrontmost: true, failingConfigSaveCalls: [2])
        let commandK = AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey))
        harness.registrar.registrationStatusesByKey[commandK.keyCode] = [noErr, OSStatus(eventHotKeyExistsErr)]
        harness.manager.setRegistrationEnabled(true, shortcut: .default)

        let outcome = harness.save(shortcut: commandK, launchAtLogin: true)

        expect(outcome.rejectionMessage?.contains("Could not register") == true, "The final registration failure must remain visible.")
        expect(outcome.rejectionMessage?.contains("Could not restore the previous configuration") == true, "A failed config rollback must be reported as a partial change.")
        expect(harness.savedConfigs.map { $0.shortcut } == [commandK], "The fixture must leave the new config on disk after rollback fails.")
        expect(harness.registrar.activeKeyCodes == [AppConfig.Shortcut.default.keyCode], "Recovery must still restore the hotkey when config rollback fails.")
        expect(!harness.loginIsEnabled, "Recovery must still restore login when config rollback fails.")
    }

    @MainActor
    private static func testSettingsSaveReportsFailedHotKeyRestore() {
        let harness = SettingsSaveHarness(finderIsFrontmost: true)
        let commandK = AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey))
        harness.manager.setRegistrationEnabled(true, shortcut: .default)
        harness.registrar.registrationStatusesByKey[commandK.keyCode] = [noErr, OSStatus(eventHotKeyExistsErr)]
        harness.registrar.registrationStatusesByKey[AppConfig.Shortcut.default.keyCode] = [noErr, OSStatus(eventHotKeyExistsErr)]

        let outcome = harness.save(shortcut: commandK, launchAtLogin: true)

        expect(outcome.rejectionMessage?.contains("Could not restore keyboard shortcut cmd+l") == true, "A failed hotkey restoration must be reported rather than only logged.")
        expect(harness.registrar.activeKeyCodes.isEmpty, "The fixture must reproduce the old shortcut also becoming unavailable.")
        expect(harness.savedConfigs.last?.shortcut == .default && !harness.loginIsEnabled, "Other recovery steps must still succeed when hotkey restoration fails.")
    }

    @MainActor
    private static func click(_ recorder: ShortcutRecorderView) {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: recorder.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
        recorder.mouseDown(with: event)
    }

    @MainActor
    private static func makeShortcutRecorderWindow() -> (ShortcutRecorderTestWindow, ShortcutRecorderView) {
        _ = NSApplication.shared
        let window = ShortcutRecorderTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let recorder = ShortcutRecorderView(frame: NSRect(x: 10, y: 10, width: 180, height: 28))
        window.contentView!.addSubview(recorder)
        return (window, recorder)
    }

    @MainActor
    private static func shortcutEvent(
        in window: NSWindow,
        keyCode: Int,
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }

    @MainActor
    private static func testCommitUsesWindowWhereEditSessionBegan() {
        let automationService = RecordingFinderAutomationService()
        let viewModel = PathBarViewModel(
            displayMode: .text,
            automationService: automationService
        )
        viewModel.update(
            state: FinderState(
                displayedPath: "/tmp",
                resolvedPath: "/tmp",
                windowID: 1
            ),
            displayMode: .text
        )

        expect(viewModel.beginEditing(), "Expected editing to begin with a current Finder state.")
        viewModel.update(
            state: FinderState(
                displayedPath: "/Users",
                resolvedPath: "/Users",
                windowID: 2
            ),
            displayMode: .text
        )
        viewModel.editingText = "/tmp"
        viewModel.commitEditing()

        expect(
            automationService.navigateRequests.isEmpty,
            "Once a Finder target change ends editing, commit must not navigate a different window implicitly."
        )
    }

    @MainActor
    private static func makeReadyViewModel() -> PathBarViewModel {
        let viewModel = PathBarViewModel(
            displayMode: .text,
            automationService: MockFinderAutomationService()
        )
        viewModel.update(
            state: FinderState(
                displayedPath: "/tmp",
                resolvedPath: "/tmp",
                windowID: 1
            ),
            displayMode: .text
        )
        return viewModel
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func testReadableShortcutDecoding() {
        let shortcut = decodeShortcut(from: #""cmd+option+l""#)
        expect(shortcut.keyCode == UInt32(kVK_ANSI_L), "Expected cmd+option+l to use the L key code.")
        expect(
            shortcut.modifiers == UInt32(cmdKey | optionKey),
            "Expected cmd+option+l to use command and option modifiers."
        )
    }

    private static func testLegacyShortcutDecoding() {
        let shortcut = decodeShortcut(from: #"{"keyCode":37,"modifiers":2560}"#)
        expect(shortcut.keyCode == 37, "Expected legacy shortcut key code to decode.")
        expect(shortcut.modifiers == 2560, "Expected legacy shortcut modifiers to decode.")
    }

    private static func testReadableShortcutEncoding() {
        let data = tryOrFail("Expected shortcut encoding to succeed.") {
            try JSONEncoder().encode(AppConfig.Shortcut.default)
        }
        let encoded = String(decoding: data, as: UTF8.self)
        expect(encoded == #""cmd+l""#, "Expected the default shortcut to encode as cmd+l.")
    }

    private static func testConfigMissingDiagnosticsFlagUsesDefault() {
        let config = tryOrFail("Expected config without diagnostics flag to decode.") {
            try JSONDecoder().decode(AppConfig.self, from: Data("""
            {
              "activePollInterval": 0.12,
              "displayMode": "text",
              "horizontalInset": 8,
              "inactivePollInterval": 1.5,
              "launchAtLogin": false,
              "motionPollInterval": 0.016,
              "motionTrackingDuration": 0.75,
              "preferredBarHeight": 34,
              "shortcut": "cmd+option+l",
              "verticalGap": -6
            }
            """.utf8))
        }

        expect(
            config.debugLogFinderWindowDiagnostics == false,
            "Older config files should keep diagnostics disabled by default."
        )
    }

    private static func testConfigIgnoresRemovedTrackingFlag() {
        let config = tryOrFail("Expected legacy config with removed tracking flag to decode.") {
            try JSONDecoder().decode(AppConfig.self, from: Data("""
            {
              "activePollInterval": 0.12,
              "displayMode": "text",
              "horizontalInset": 8,
              "inactivePollInterval": 1.5,
              "launchAtLogin": false,
              "motionPollInterval": 0.016,
              "motionTrackingDuration": 0.75,
              "preferredBarHeight": 34,
              "shortcut": "cmd+option+l",
              "trackOnlyFrontmostFinderWindow": false,
              "verticalGap": -6
            }
            """.utf8))
        }

        expect(
            config.shortcut == decodeShortcut(from: #""cmd+option+l""#),
            "Legacy configs should preserve their explicitly configured shortcut."
        )
    }

    private static func testConfigSanitizesInvalidPollingIntervals() {
        var config = AppConfig.default
        config.activePollInterval = 0
        config.motionPollInterval = -1
        config.inactivePollInterval = -.infinity

        let sanitized = config.sanitized()

        expect(
            sanitized.activePollInterval == AppConfig.default.activePollInterval,
            "A zero active interval must not create a continuously firing timer."
        )
        expect(
            sanitized.motionPollInterval == AppConfig.default.motionPollInterval,
            "A negative motion interval must fall back to the safe default."
        )
        expect(
            sanitized.inactivePollInterval == AppConfig.default.inactivePollInterval,
            "A non-finite inactive interval must fall back to the safe default."
        )
    }

    private static func testShortcutValidationPolicy() {
        for valid in ["cmd+l", "cmd+shift+a", "control+a", "cmd+option+l", "control+space", "cmd+left", "option+f5", "option+shift+f12"] {
            expect(decodeShortcut(from: "\"\(valid)\"").validationProblem == nil, "\(valid) should be an allowed shortcut.")
        }
        for invalid in ["a", "shift+a", "option+l", "option+shift+l", "shift+tab", "option+left", "shift+space", "f5", "shift+f5"] {
            expect(decodeShortcut(from: "\"\(invalid)\"").validationProblem != nil, "\(invalid) can interfere with typing and must be rejected.")
        }
        let unknownModifier = AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | alphaLock))
        expect(unknownModifier.validationProblem != nil, "Unsupported modifier bits must be rejected.")
        expect(AppConfig.Shortcut.default.validationProblem == nil, "The Command-L default must remain valid.")
        expect(decodeShortcut(from: "\"option+f5\"").description == "option+f5", "Function keys should round-trip by name.")
    }

    private static func testConfigTextInputShortcutFallsBackAlone() {
        let config = decodeConfig(shortcutJSON: "\"shift+a\"").sanitized()
        expect(config.shortcut == .default, "A text-input shortcut must fall back to Command-L.")
        expect(config.displayMode == .breadcrumb, "Shortcut fallback must keep the configured display mode.")
        expect(config.activePollInterval == 0.2, "Shortcut fallback must keep other valid settings.")
    }

    private static func testConfigUnreadableShortcutFallsBackAlone() {
        let config = decodeConfig(shortcutJSON: "\"cmd+banana\"").sanitized()
        expect(config.shortcut == .default, "An unreadable shortcut must fall back to Command-L.")
        expect(config.displayMode == .breadcrumb, "An unreadable shortcut must not discard the display mode.")
        expect(config.activePollInterval == 0.2, "An unreadable shortcut must not discard other settings.")
    }

    private static func testConfigPreservesValidShortcuts() {
        for (json, expected) in [
            ("\"control+option+k\"", AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))),
            ("{\"keyCode\":37,\"modifiers\":256}", AppConfig.Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey))),
            ("\"option+f5\"", AppConfig.Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(optionKey)))
        ] {
            expect(decodeConfig(shortcutJSON: json).sanitized().shortcut == expected, "Valid shortcut \(json) must be preserved.")
        }
    }

    private static func decodeConfig(shortcutJSON: String) -> AppConfig {
        tryOrFail("Expected config with shortcut \(shortcutJSON) to decode.") {
            try JSONDecoder().decode(AppConfig.self, from: Data("""
            {
              "activePollInterval": 0.2,
              "displayMode": "breadcrumb",
              "shortcut": \(shortcutJSON)
            }
            """.utf8))
        }
    }

    private static func testNavigationAcceptsNonTextAppleScriptResult() {
        let descriptor = NSAppleEventDescriptor.null()
        let executor = MockAppleScriptExecutor(result: descriptor)
        let service = FinderAutomationService(scriptExecutor: executor)

        expect(descriptor.stringValue == nil, "The regression fixture must use a non-text AppleScript result.")
        expect(
            service.navigate(to: NSTemporaryDirectory(), windowID: 1),
            "An error-free non-text AppleScript result should count as successful navigation."
        )
        expect(executor.executeCalls == 1, "Navigation should execute exactly one AppleScript.")
    }

    private static func testNavigationScriptCannotRetargetAnotherWindow() {
        let executor = MockAppleScriptExecutor(result: .null())
        let service = FinderAutomationService(scriptExecutor: executor)
        expect(service.navigate(to: NSTemporaryDirectory(), windowID: 42), "A targeted navigation should accept an error-free response.")
        let source = executor.lastScriptSource ?? ""
        var compileError: NSDictionary?
        let script = NSAppleScript(source: source)
        expect(script?.compileAndReturnError(&compileError) == true, "The emitted navigation command must compile against Finder's dictionary: \(String(describing: compileError))")
        expect(source.contains("first Finder window whose id is 42"), "The emitted Finder command must address the pinned window.")
        expect(!source.contains("Finder window 1"), "A targeted command must never fall back to an unrelated front window.")
        expect(!source.contains("make new Finder window"), "A targeted command must never replace a closed window implicitly.")
    }

    private static func testMissingNavigationWindowFailsWithoutRetry() {
        let executor = MockAppleScriptExecutor(
            result: .null(),
            error: [NSAppleScript.errorNumber: -1728, NSAppleScript.errorMessage: "Window no longer exists"]
        )
        let service = FinderAutomationService(scriptExecutor: executor)
        expect(!service.navigate(to: NSTemporaryDirectory(), windowID: 42), "A missing pinned window must report failure.")
        expect(executor.executeCalls == 1, "A missing window must not trigger a second request to another window.")
        expect(executor.lastScriptSource?.contains("error \"The Finder window being edited is no longer available.\" number -1728") == true, "The emitted command must fail when Finder no longer has the pinned window.")
    }

    private static func testUntargetedNavigationStillAllowsOpeningAWindow() {
        let executor = MockAppleScriptExecutor(result: .null())
        let service = FinderAutomationService(scriptExecutor: executor)
        expect(service.navigate(to: NSTemporaryDirectory(), windowID: nil), "Navigation without a pinned window should remain supported.")
        expect(executor.lastScriptSource?.contains("make new Finder window") == true, "Only untargeted navigation may open a new window when needed.")
    }

    private static func testFinderStateAcceptsFileURLFallback() {
        expect(
            FinderAutomationService.parseFinderStateResponse("42\n\n\nfile:///") == FinderState(
                displayedPath: "/",
                resolvedPath: "/",
                windowID: 42
            ),
            "Finder file URLs should recover targets that cannot coerce to aliases or text."
        )
    }

    private static func testFinderStateRecoversClassCodedAFPPath() {
        // Captured from a live AFP Finder tab whose target was readable on disk
        // but failed alias, text, and URL coercion with AppleScript error -1700.
        let finderError = """
        Can't make «class cfol» "movies" of «class cfol» "plex" of «class cfol» "Thanos" of «class cfol» "Drive" of «class cdis» "home" of application "Finder" into type string.
        """
        expect(
            FinderAutomationService.parseFinderStateResponse("61\n\n\(finderError)\n") == FinderState(
                displayedPath: "/Volumes/home/Drive/Thanos/plex/movies",
                resolvedPath: "/Volumes/home/Drive/Thanos/plex/movies",
                windowID: 61
            ),
            "Finder's class-coded AFP error should recover the complete mounted path."
        )
    }

    private static func testFinderStateScriptProtectsDescriptionCoercion() {
        expect(
            FinderAutomationService.currentStateScriptSource.contains("on error errorMessage")
                && FinderAutomationService.currentStateScriptSource.contains(
                    "set targetDescription to errorMessage"
                ),
            "Finder description coercion failures must be preserved for AFP path recovery."
        )
    }

    private static func testFinderStateRefreshCacheThrottlesMotionPolling() {
        var cache = FinderStateRefreshCache()
        var loadCount = 0
        let initialDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let expectedState = FinderState(
            displayedPath: "/tmp",
            resolvedPath: "/private/tmp",
            windowID: 1
        )

        func refreshState(at date: Date, forceRefresh: Bool = false) -> FinderState? {
            guard cache.shouldRefresh(
                now: date,
                minimumInterval: 0.12,
                forceRefresh: forceRefresh
            ) else {
                return cache.lastKnownState
            }
            loadCount += 1
            recordRead(&cache, expectedState, at: date)
            return cache.lastKnownState
        }

        _ = refreshState(at: initialDate)
        _ = refreshState(at: initialDate.addingTimeInterval(0.016))

        expect(loadCount == 1, "A 16 ms frame poll should reuse the cached Finder path state.")

        let refreshedState = refreshState(at: initialDate.addingTimeInterval(0.121))
        expect(loadCount == 2, "Finder path state should refresh after the normal active interval.")
        expect(refreshedState == expectedState, "Refreshing should return the latest Finder state.")

        _ = refreshState(at: initialDate.addingTimeInterval(0.122), forceRefresh: true)
        expect(loadCount == 3, "Explicit refreshes must bypass the path-state cache.")
    }

    private static func testFinderReadFailuresCannotRenewOldPaths() {
        var cache = FinderStateRefreshCache()
        let initialDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let state = FinderState(displayedPath: "/tmp", resolvedPath: "/tmp", windowID: 42)
        recordRead(&cache, state, at: initialDate)

        for elapsed in [0.125, 0.249] {
            let now = initialDate.addingTimeInterval(elapsed)
            recordRead(&cache, nil, at: now)
            expect(cache.lookup(windowNumber: 42, now: now, maximumAge: 0.25, pendingReadGrace: 1.5, isShowingPath: true) == .current(state), "A short failure should retain a matching path.")
        }
        for elapsed in [0.25, 0.5, 1.0, 5.0] {
            let now = initialDate.addingTimeInterval(elapsed)
            // A retry is already running, but a confirmed failure gets no read grace.
            let retryID = cache.beginRead(at: now)
            for isShowingPath in [true, false] {
                expect(cache.lookup(windowNumber: 42, now: now, maximumAge: 0.25, pendingReadGrace: 1.5, isShowingPath: isShowingPath) == .unavailable, "Repeated failures must never extend a stale path.")
            }
            cache.completeRead(retryID, state: nil, at: now)
        }
    }

    private static func testFinderSlowReadGraceIsBoundedAndRecovers() {
        var cache = FinderStateRefreshCache()
        let initialDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let oldState = FinderState(displayedPath: "/tmp", resolvedPath: "/tmp", windowID: 42)
        recordRead(&cache, oldState, at: initialDate)
        func lookup(after elapsed: TimeInterval, isShowingPath: Bool = true) -> FinderStateRefreshCache.Lookup {
            cache.lookup(windowNumber: 42, now: initialDate.addingTimeInterval(elapsed), maximumAge: 0.25, pendingReadGrace: 1.5, isShowingPath: isShowingPath)
        }

        expect(lookup(after: 0.5) == .unavailable, "An expired path with no read running must not stay visible.")
        expect(lookup(after: 0.5, isShowingPath: false) == .pending, "A hidden bar should wait for a read instead of showing a placeholder.")

        let readID = cache.beginRead(at: initialDate.addingTimeInterval(0.2))
        expect(lookup(after: 0.5) == .current(oldState), "Ordinary read latency should not flicker a visible path.")
        expect(lookup(after: 1.6) == .current(oldState), "The visible path may survive a slow read briefly.")
        expect(lookup(after: 1.8) == .unavailable, "A stuck read must not preserve the old path indefinitely.")
        expect(lookup(after: 10, isShowingPath: false) == .pending, "A hidden bar must stay hidden rather than show a stuck path.")

        let freshState = FinderState(displayedPath: "/Users", resolvedPath: "/Users", windowID: 42)
        cache.completeRead(readID, state: freshState, at: initialDate.addingTimeInterval(2))
        expect(lookup(after: 2) == .current(freshState), "A successful read must immediately restore the fresh path.")
    }

    private static func testFinderCacheNeverUsesAnotherWindowsPath() {
        var cache = FinderStateRefreshCache()
        let initialDate = Date(timeIntervalSinceReferenceDate: 1_000)
        expect(cache.lookup(windowNumber: 42, now: initialDate, maximumAge: 0.25, pendingReadGrace: 1.5, isShowingPath: false) == .unknownWindow, "A cold cache cannot fabricate a Finder window.")
        recordRead(&cache, FinderState(displayedPath: "/tmp", resolvedPath: "/tmp", windowID: 42), at: initialDate)
        for elapsed in [0.125, 1.0] {
            let now = initialDate.addingTimeInterval(elapsed)
            recordRead(&cache, nil, at: now)
            expect(cache.lookup(windowNumber: 43, now: now, maximumAge: 0.25, pendingReadGrace: 1.5, isShowingPath: true) == .unknownWindow, "Neither a cached path nor its unavailable state should be attached to a different window.")
        }
    }

    private static func testFinderCacheRejectsReadsStartedBeforeActivation() {
        var cache = FinderStateRefreshCache()
        let initialDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let oldState = FinderState(displayedPath: "/tmp", resolvedPath: "/tmp", windowID: 42)
        recordRead(&cache, oldState, at: initialDate)
        let staleReadID = cache.beginRead(at: initialDate.addingTimeInterval(0.05))
        let activationDate = initialDate.addingTimeInterval(0.1)
        cache.requireFreshRead(at: activationDate)

        expect(cache.shouldRefresh(now: activationDate, minimumInterval: 0.12, forceRefresh: false), "Activation must request a read even while an older one runs.")
        expect(cache.lookup(windowNumber: 42, now: activationDate, maximumAge: 0.25, pendingReadGrace: 1.5, isShowingPath: false) == .pending, "A hidden bar must wait for a post-activation read.")

        let changedState = FinderState(displayedPath: "/Users", resolvedPath: "/Users", windowID: 42)
        cache.completeRead(staleReadID, state: changedState, at: activationDate.addingTimeInterval(0.01))
        expect(cache.lastKnownState == oldState, "A read that started before activation must be discarded.")
        expect(cache.lookup(windowNumber: 42, now: activationDate.addingTimeInterval(0.01), maximumAge: 0.25, pendingReadGrace: 1.5, isShowingPath: false) == .pending, "A stale read cannot satisfy activation.")

        let freshReadID = cache.beginRead(at: activationDate.addingTimeInterval(0.02))
        cache.completeRead(freshReadID, state: changedState, at: activationDate.addingTimeInterval(0.05))
        expect(cache.lookup(windowNumber: 42, now: activationDate.addingTimeInterval(0.05), maximumAge: 0.25, pendingReadGrace: 1.5, isShowingPath: false) == .current(changedState), "A post-activation read should show its path.")
    }

    private static func recordRead(_ cache: inout FinderStateRefreshCache, _ state: FinderState?, at date: Date) {
        let readID = cache.beginRead(at: date)
        cache.completeRead(readID, state: state, at: date)
    }

    private static let tmp42 = FinderState(displayedPath: "/tmp", resolvedPath: "/tmp", windowID: 42)
    private static let users42 = FinderState(displayedPath: "/Users", resolvedPath: "/Users", windowID: 42)
    private static let users43 = FinderState(displayedPath: "/Users", resolvedPath: "/Users", windowID: 43)

    private static func shown(_ state: FinderState?) -> FinderWindowTrackerUpdate {
        .snapshot(FinderWindowSnapshot(frame: ScriptedFinderEnvironment.frame, state: state))
    }

    @MainActor
    private static func testTrackerActivationAfterInactivityWaitsForFreshRead() {
        let harness = TrackerHarness.showing(tmp42)
        expect(harness.updates == [shown(tmp42)], "The first successful read should show the bar.")

        harness.finder.isFinderFrontmost = false
        harness.finder.advance(0.1)
        harness.tracker.poll()
        expect(harness.updates.last == .hidden, "Switching apps must hide the bar immediately.")

        harness.finder.advance(30)
        harness.finder.isFinderFrontmost = true
        let updatesBeforeActivation = harness.updates.count
        harness.tracker.poll()
        harness.finder.advance(0.3)
        harness.tracker.poll()
        expect(harness.updates.count == updatesBeforeActivation, "Returning to Finder must neither flash a placeholder nor show the pre-inactivity path.")
        expect(harness.finder.pendingReadCount == 1, "Activation should start exactly one fresh read.")

        harness.finder.finishRead(with: users42, after: 0.05)
        expect(harness.updates.last == shown(users42), "The bar should reappear with the post-activation path.")
        expect(!harness.didShowUnavailablePlaceholder, "Inactivity alone must never show the unavailable placeholder.")
        harness.tracker.stop()
    }

    @MainActor
    private static func testTrackerSlowReadKeepsVisiblePathOnlyBriefly() {
        let harness = TrackerHarness.showing(tmp42)
        harness.finder.advance(0.15)
        harness.tracker.poll()
        expect(harness.finder.pendingReadCount == 1, "A routine poll should start a read.")
        harness.finder.advance(0.4)
        harness.tracker.poll()
        harness.finder.finishRead(with: tmp42, after: 0.1)
        expect(harness.updates == [shown(tmp42)], "Ordinary read latency must not oscillate the label.")

        harness.finder.advance(0.2)
        harness.tracker.poll()
        harness.finder.advance(1.4)
        harness.tracker.poll()
        expect(harness.updates == [shown(tmp42)], "A slow read may keep a visible path briefly.")
        harness.finder.advance(0.2)
        harness.tracker.poll()
        expect(harness.updates.last == shown(nil), "A stuck read must expire the editable path.")

        harness.finder.finishRead(with: users42, after: 0.1)
        expect(harness.updates.last == shown(users42), "A later successful read must restore the path.")
        harness.tracker.stop()
    }

    @MainActor
    private static func testTrackerFailedReadExpiresDespitePendingRetry() {
        let harness = TrackerHarness.showing(tmp42)
        let viewModel = PathBarViewModel(displayMode: .text, automationService: RecordingFinderAutomationService())
        viewModel.update(state: tmp42, displayMode: .text)
        expect(viewModel.beginEditing(), "A current path should permit editing.")

        harness.finder.advance(0.15)
        harness.tracker.poll()
        harness.finder.finishRead(with: nil, after: 0.01)
        expect(harness.updates == [shown(tmp42)], "A single recent failure may reuse the path briefly.")

        harness.finder.advance(0.13)
        harness.tracker.poll()
        expect(harness.finder.pendingReadCount == 1, "A retry should be running.")
        expect(harness.updates.last == shown(nil), "A confirmed failure must expire the path even while a retry runs.")
        harness.applyLastSnapshot(to: viewModel)
        expect(viewModel.currentState == nil, "Expiry must clear the view model path.")
        expect(!viewModel.isEditing, "Expiry must end editing.")
        expect(viewModel.displayedText == "Finder location unavailable", "Expiry must show the unavailable message.")

        harness.finder.finishRead(with: tmp42, after: 0.02)
        expect(harness.updates.last == shown(tmp42), "A successful retry must restore the path.")
        harness.applyLastSnapshot(to: viewModel)
        expect(viewModel.beginEditing(), "Recovery must restore editing.")
        harness.tracker.stop()
    }

    @MainActor
    private static func testTrackerWindowSwitchNeverPairsAnotherWindowsPath() {
        let harness = TrackerHarness.showing(tmp42)
        harness.finder.window = ScriptedFinderEnvironment.window(number: 43)
        harness.finder.advance(0.02)
        harness.tracker.poll()
        expect(harness.updates == [shown(tmp42), .hidden], "A different window must hide the bar until its own read finishes.")

        harness.finder.finishRead(with: tmp42, after: 0.03)
        expect(harness.updates == [shown(tmp42), .hidden], "A path for window 42 must never be shown on window 43.")

        harness.finder.advance(0.15)
        harness.tracker.poll()
        harness.finder.finishRead(with: users43, after: 0.02)
        expect(harness.updates.last == shown(users43), "The new window should show its own path.")

        harness.finder.window = ScriptedFinderEnvironment.window(number: 42)
        harness.finder.advance(0.02)
        harness.tracker.poll()
        expect(harness.updates.last == .hidden, "Returning to an earlier window must wait for a fresh read.")
        harness.finder.finishRead(with: tmp42, after: 0.02)
        expect(harness.updates.last == shown(tmp42), "The earlier window should recover with its fresh path.")
        expect(!harness.didShowUnavailablePlaceholder, "Window switches alone must not show the unavailable placeholder.")
        harness.tracker.stop()
    }

    @MainActor
    private static func testTrackerRejectsPreHotKeyReadFromSameWindow() {
        let harness = TrackerHarness.showing(tmp42)
        harness.finder.advance(0.15)
        harness.tracker.poll()
        expect(harness.finder.startedReadCount == 2, "A routine polling read should be running before the press.")

        var results: [FinderWindowSnapshot?] = []
        harness.tracker.requestFreshSnapshot { results.append($0) }
        expect(harness.finder.startedReadCount == 2, "The press should wait for the running read instead of overlapping it.")

        harness.finder.finishRead(with: tmp42, after: 0.02)
        expect(results.isEmpty, "A read started before the press must not open the editor, even for the same window.")
        expect(harness.finder.startedReadCount == 3, "A read that starts after the press should follow.")

        harness.finder.finishRead(with: users42, after: 0.02)
        expect(results == [FinderWindowSnapshot(frame: ScriptedFinderEnvironment.frame, state: users42)], "Only the post-press read may open the editor.")
        expect(harness.finder.pendingReadCount == 0, "A satisfied press must not leave extra reads.")
        harness.tracker.stop()
    }

    @MainActor
    private static func testTrackerHotKeyRejectsReadDiscardedAfterWindowSwitch() {
        verifyHotKeyWindowTransition(pollBeforeCompletion: true)
    }

    @MainActor
    private static func testTrackerHotKeyChecksWindowFreshnessAfterPolling() {
        verifyHotKeyWindowTransition(pollBeforeCompletion: false)
    }

    @MainActor
    private static func verifyHotKeyWindowTransition(pollBeforeCompletion: Bool) {
        let harness = TrackerHarness.showing(tmp42)
        var results: [FinderWindowSnapshot?] = []
        harness.tracker.requestFreshSnapshot { results.append($0) }
        harness.finder.window = ScriptedFinderEnvironment.window(number: 43)
        if pollBeforeCompletion {
            harness.tracker.poll()
        }

        // This read started before the switch but sampled the newly frontmost
        // window. Matching IDs alone do not prove the result is fresh enough.
        harness.finder.finishRead(with: users43, after: 0.02)
        expect(results.isEmpty, "A read predating a window transition must not open the editor, even if its window ID matches.")
        expect(harness.finder.pendingReadCount == 1, "The editor must wait for the transition's required read.")
        let freshState = FinderState(displayedPath: "/Applications", resolvedPath: "/Applications", windowID: 43)
        harness.finder.finishRead(with: freshState, after: 0.02)
        expect(results == [FinderWindowSnapshot(frame: ScriptedFinderEnvironment.frame, state: freshState)], "Only the read accepted after the window transition may open the editor.")
        expect(harness.finder.pendingReadCount == 0, "A satisfied edit request must not queue another read.")
        harness.tracker.stop()
    }

    @MainActor
    private static func testTrackerCoalescesHotKeyPressesAndForcedRefreshes() {
        let harness = TrackerHarness.showing(tmp42)
        harness.finder.advance(0.15)
        harness.tracker.poll()

        var first: [FinderWindowSnapshot?] = []
        var second: [FinderWindowSnapshot?] = []
        var third: [FinderWindowSnapshot?] = []
        harness.tracker.requestFreshSnapshot { first.append($0) }
        harness.tracker.requestFreshSnapshot { second.append($0) }
        harness.tracker.refreshNow()
        harness.tracker.refreshNow()
        expect(first == [nil], "A superseded press should finish without editing.")
        expect(harness.finder.startedReadCount == 2, "Presses and forced refreshes must not start overlapping reads.")

        harness.finder.finishRead(with: tmp42, after: 0.02)
        expect(second.isEmpty, "The routine read predates the latest press.")
        expect(harness.finder.startedReadCount == 3, "All pending requests should share one follow-up read.")
        expect(harness.finder.pendingReadCount == 1, "Only one read may be outstanding.")

        harness.tracker.requestFreshSnapshot { third.append($0) }
        expect(second == [nil], "A newer press supersedes the previous one.")
        harness.finder.finishRead(with: tmp42, after: 0.02)
        expect(third.isEmpty, "A read started before the newest press must be rejected.")
        expect(harness.finder.startedReadCount == 4, "The newest press should get one newer read.")

        harness.finder.finishRead(with: users42, after: 0.02)
        expect(third == [FinderWindowSnapshot(frame: ScriptedFinderEnvironment.frame, state: users42)], "The newest press should open with the newest path.")
        expect(harness.finder.pendingReadCount == 0, "Coalesced requests must not leave a queue of reads.")
        harness.tracker.stop()
    }

    @MainActor
    private static func testTrackerHotKeyRequestCancellationRejectsLateReads() {
        let harness = TrackerHarness.showing(tmp42)

        var switchedApp: [FinderWindowSnapshot?] = []
        harness.tracker.requestFreshSnapshot { switchedApp.append($0) }
        expect(harness.finder.pendingReadCount == 1, "An idle tracker should start a read for the press.")
        harness.finder.isFinderFrontmost = false
        harness.tracker.poll()
        expect(switchedApp == [nil], "Leaving Finder must cancel the press.")
        harness.finder.finishRead(with: tmp42, after: 0.02)
        expect(switchedApp == [nil], "A read finishing after an app switch must not open the editor.")
        expect(harness.finder.pendingReadCount == 0, "A cancelled press must not leave follow-up reads.")

        harness.finder.isFinderFrontmost = true
        harness.finder.advance(1)
        harness.tracker.poll()
        harness.finder.finishRead(with: tmp42, after: 0.02)
        var timedOut: [FinderWindowSnapshot?] = []
        harness.tracker.requestFreshSnapshot { timedOut.append($0) }
        harness.tracker.cancelFreshSnapshotRequest()
        expect(timedOut == [nil], "A timeout should end the press immediately.")
        harness.finder.finishRead(with: tmp42, after: 0.02)
        expect(timedOut == [nil], "A read finishing after a timeout must not open the editor.")

        var switchedWindow: [FinderWindowSnapshot?] = []
        harness.tracker.requestFreshSnapshot { switchedWindow.append($0) }
        harness.finder.window = ScriptedFinderEnvironment.window(number: 43)
        harness.finder.finishRead(with: tmp42, after: 0.02)
        expect(switchedWindow.isEmpty, "A result for the previous window must not open the editor.")
        expect(harness.finder.pendingReadCount == 1, "A window switch should allow one newer read.")
        harness.finder.window = ScriptedFinderEnvironment.window(number: 44)
        harness.finder.finishRead(with: users43, after: 0.02)
        expect(switchedWindow == [nil], "A second window mismatch must give up without editing.")
        harness.tracker.stop()
    }

    private static func testLiveResizeBypassesPollSuppression() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let suppressionDeadline = now.addingTimeInterval(0.35)

        expect(
            !FinderMotionHidingPolicy.shouldHide(
                source: .polledMove,
                suppressionDeadline: suppressionDeadline,
                now: now
            ),
            "Late polled position changes should remain suppressed while the bar settles."
        )
        expect(
            FinderMotionHidingPolicy.shouldHide(
                source: .polledResize,
                suppressionDeadline: suppressionDeadline,
                now: now
            ),
            "A polled size change must hide the bar throughout a live Finder resize."
        )
        expect(
            FinderMotionHidingPolicy.shouldHide(
                source: .accessibilityNotification,
                suppressionDeadline: suppressionDeadline,
                now: now
            ),
            "An explicit Accessibility resize must hide the bar even during poll suppression."
        )
    }

    private static func testMotionHidingWaitsForMouseRelease() {
        expect(
            !FinderMotionCompletionPolicy.shouldFinish(isResizeDragInProgress: true),
            "The bar must remain hidden while the Finder move or resize drag is active."
        )
        expect(
            FinderMotionCompletionPolicy.shouldFinish(isResizeDragInProgress: false),
            "The bar may reappear after the Finder move or resize drag is released."
        )
    }

    private static func testFinderResizeBorderHitTesting() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

        expect(
            FinderResizeHitTester.isResizeBorderHit(point: CGPoint(x: 898, y: 698), frame: frame),
            "A Finder window corner should begin resize hiding immediately."
        )
        expect(
            FinderResizeHitTester.isResizeBorderHit(point: CGPoint(x: 116, y: 116), frame: frame),
            "Finder's rounded upper corners should use the wider corner hit zone."
        )
        expect(
            FinderResizeHitTester.isResizeBorderHit(point: CGPoint(x: 500, y: 699), frame: frame),
            "A Finder window edge should begin resize hiding immediately."
        )
        expect(
            !FinderResizeHitTester.isResizeBorderHit(point: CGPoint(x: 130, y: 130), frame: frame),
            "The wider corner hit zone must not extend into ordinary Finder content."
        )
        expect(
            !FinderResizeHitTester.isResizeBorderHit(point: CGPoint(x: 500, y: 400), frame: frame),
            "A click inside Finder content must not be mistaken for a resize drag."
        )
    }

    private static func testQuickLookAXWindowDetection() {
        expect(
            QuickLookAXWindowDetector.isPreviewWindow(
                role: "AXWindow",
                subrole: "Quick Look",
                title: "Vista rapida"
            ),
            "Finder's Quick Look AX subrole should suppress the bar regardless of its localized title."
        )
        expect(
            !QuickLookAXWindowDetector.isPreviewWindow(
                role: "AXWindow",
                subrole: "AXStandardWindow",
                title: "Documents"
            ),
            "A normal Finder window must not be classified as Quick Look."
        )
        expect(
            !QuickLookAXWindowDetector.isPreviewWindow(
                role: "AXWindow",
                subrole: "AXUnknown",
                title: nil
            ),
            "Finder's transient unknown AX window must not be classified as Quick Look."
        )
    }

    private static func testDragToInstallVolumeDetection() {
        let installerVolume = InstallerVolumeCharacteristics(
            isVolumeRoot: true,
            isLocal: true,
            isReadOnly: true,
            isEjectable: true,
            isRemovable: true
        )

        expect(
            DragToInstallVolumePolicy.shouldHideBar(
                characteristics: installerVolume,
                containsAppBundle: true,
                symlinkDestinations: ["/Applications"]
            ),
            "A read-only installer volume with an app and Applications link should hide the bar."
        )
        expect(
            !DragToInstallVolumePolicy.shouldHideBar(
                characteristics: installerVolume,
                containsAppBundle: false,
                symlinkDestinations: ["/Applications"]
            ),
            "A mounted image without an app bundle should remain visible."
        )
        expect(
            !DragToInstallVolumePolicy.shouldHideBar(
                characteristics: installerVolume,
                containsAppBundle: true,
                symlinkDestinations: []
            ),
            "A mounted image without an Applications link should remain visible."
        )

        var externalDrive = installerVolume
        externalDrive.isReadOnly = false
        externalDrive.isRemovable = false
        expect(
            !DragToInstallVolumePolicy.shouldHideBar(
                characteristics: externalDrive,
                containsAppBundle: true,
                symlinkDestinations: ["/Applications"]
            ),
            "A writable external drive must not be mistaken for an installer DMG."
        )

        var installerSubdirectory = installerVolume
        installerSubdirectory.isVolumeRoot = false
        expect(
            !DragToInstallVolumePolicy.shouldHideBar(
                characteristics: installerSubdirectory,
                containsAppBundle: true,
                symlinkDestinations: ["/Applications"]
            ),
            "Only an installer volume's root Finder window should hide the bar."
        )

        var networkVolume = installerVolume
        networkVolume.isLocal = false
        expect(
            !DragToInstallVolumePolicy.shouldHideBar(
                characteristics: networkVolume,
                containsAppBundle: true,
                symlinkDestinations: ["/Applications"]
            ),
            "A network volume must not be mistaken for a local installer DMG."
        )
    }

    private static func testFinderPollReentrancyIsCoalesced() {
        var gate = FinderPollReentrancyGate()

        expect(gate.begin(forceRefresh: false), "The first Finder poll should begin immediately.")
        expect(
            !gate.begin(forceRefresh: true),
            "A Finder notification received during AppleScript execution must not re-enter polling."
        )

        let pendingPoll = gate.finish()
        expect(pendingPoll.shouldPoll, "A nested Finder notification should schedule one follow-up poll.")
        expect(pendingPoll.forceRefresh, "A nested forced refresh must be preserved for the follow-up poll.")
        expect(gate.begin(forceRefresh: false), "The gate should reopen after the active poll finishes.")
        _ = gate.finish()
    }

    private static func testFreshSnapshotRequestsCoalesceAndRetryOnce() {
        var state = FinderFreshSnapshotRequestState()

        expect(state.begin(nextReadID: 1, isReadInFlight: false), "The first press should start a Finder read.")
        expect(state.accepts(readID: 1), "A read started after the press should be accepted.")
        expect(!state.begin(nextReadID: 2, isReadInFlight: true), "A repeated press must wait for the running read.")
        expect(!state.accepts(readID: 1), "A read started before the latest press must be rejected.")
        expect(state.accepts(readID: 2), "The follow-up read should satisfy the repeated press.")
        expect(state.consumeRetryIfAvailable(finderIsFrontmost: true, after: 2), "A mismatched result should permit one retry.")
        expect(!state.accepts(readID: 2), "The retry must use a newer read.")
        expect(!state.consumeRetryIfAvailable(finderIsFrontmost: true, after: 3), "Repeated presses must not replenish the retry allowance.")
        _ = state.begin(nextReadID: 4, isReadInFlight: true)
        expect(!state.consumeRetryIfAvailable(finderIsFrontmost: true, after: 4), "A press while active must not restore a used retry.")

        state.finish()
        expect(!state.accepts(readID: 9), "A finished request accepts no reads.")
        expect(state.begin(nextReadID: 9, isReadInFlight: false), "The next press should start a read.")
        expect(!state.consumeRetryIfAvailable(finderIsFrontmost: false, after: 9), "No retry is allowed after Finder loses focus.")
    }

    private static func testFreshFinderWindowPairingRequiresMatchingWindowID() {
        expect(
            FinderWindowPairingPolicy.matches(windowNumber: 42, finderStateWindowID: 42),
            "Fresh Finder state should pair with the matching frontmost window."
        )
        expect(
            !FinderWindowPairingPolicy.matches(windowNumber: 41, finderStateWindowID: 42),
            "Stale Finder state must not pair with a different frontmost window."
        )
        expect(
            FinderWindowPairingPolicy.matches(windowNumber: nil, finderStateWindowID: 42),
            "Window pairing should preserve the existing fallback when CG omits a window number."
        )
    }

    private static func testHotKeyEditRequestRejectsStaleAndCancelledResults() {
        var gate = HotKeyEditRequestGate()
        let supersededRequest = gate.begin()
        let currentRequest = gate.begin()

        expect(
            !gate.consume(
                requestID: supersededRequest,
                finderIsFrontmost: true,
                hasFreshSnapshot: true
            ),
            "A late result from a superseded hotkey request must not begin editing."
        )
        expect(
            gate.consume(
                requestID: currentRequest,
                finderIsFrontmost: true,
                hasFreshSnapshot: true
            ),
            "The current request should begin editing with a fresh matching snapshot."
        )
        expect(
            !gate.consume(
                requestID: currentRequest,
                finderIsFrontmost: true,
                hasFreshSnapshot: true
            ),
            "A hotkey request must be consumed at most once."
        )

        let cancelledRequest = gate.begin()
        gate.cancel()
        expect(
            !gate.consume(
                requestID: cancelledRequest,
                finderIsFrontmost: true,
                hasFreshSnapshot: true
            ),
            "Switching away from Finder must invalidate a pending hotkey request."
        )

        let failedRequest = gate.begin()
        expect(
            !gate.consume(
                requestID: failedRequest,
                finderIsFrontmost: true,
                hasFreshSnapshot: false
            ),
            "A failed fresh-state request must not begin editing."
        )

        let timedOutRequest = gate.begin()
        gate.cancel(requestID: timedOutRequest)
        expect(
            !gate.consume(
                requestID: timedOutRequest,
                finderIsFrontmost: true,
                hasFreshSnapshot: true
            ),
            "A fresh Finder result arriving after the hotkey timeout must be ignored."
        )

        let latestRequest = gate.begin()
        expect(!gate.cancel(requestID: timedOutRequest), "A stale timeout must report that it cancelled nothing.")
        expect(
            gate.consume(
                requestID: latestRequest,
                finderIsFrontmost: true,
                hasFreshSnapshot: true
            ),
            "A stale timeout must not cancel a newer hotkey request."
        )
        let pendingRequest = gate.begin()
        expect(gate.cancel(requestID: pendingRequest), "A current timeout should cancel its own request.")
    }

    private static func testHotKeyRegistrationReturnsRegisterFailure() {
        let registrar = MockHotKeyRegistrar(registerStatus: OSStatus(eventHotKeyExistsErr))
        let manager = HotKeyManager(registrar: registrar)
        let status = manager.register(shortcut: AppConfig.Shortcut.default)

        expect(status == OSStatus(eventHotKeyExistsErr), "HotKeyManager should return Carbon registration failures.")
        expect(registrar.installHandlerCalls == 0, "Handler installation should not run after registration failure.")
    }

    private static func testHotKeyRegistrationReturnsHandlerFailureAndCleansUp() {
        let registrar = MockHotKeyRegistrar(installHandlerStatus: OSStatus(eventInternalErr))
        let manager = HotKeyManager(registrar: registrar)
        let status = manager.register(shortcut: AppConfig.Shortcut.default)

        expect(status == OSStatus(eventInternalErr), "HotKeyManager should return handler installation failures.")
        expect(registrar.unregisterCalls == 1, "HotKeyManager should unregister a hotkey after handler installation fails.")
    }

    private static func testHotKeyRegistrationSuccessInstallsHandler() {
        let registrar = MockHotKeyRegistrar()
        let manager = HotKeyManager(registrar: registrar)
        let status = manager.register(shortcut: AppConfig.Shortcut.default)

        expect(status == noErr, "HotKeyManager should return noErr after successful registration.")
        expect(registrar.registerCalls == 1, "Expected one hotkey registration call.")
        expect(registrar.installHandlerCalls == 1, "Expected one handler installation call.")
    }

    private static func testInactiveHotKeyDoesNotRegister() {
        let registrar = MockHotKeyRegistrar()
        let manager = HotKeyManager(registrar: registrar)
        let status = manager.setRegistrationEnabled(false, shortcut: AppConfig.Shortcut.default)

        expect(status == noErr, "Disabling an inactive hotkey should succeed.")
        expect(registrar.registerCalls == 0, "The shortcut must not be reserved while Finder is inactive.")
        expect(registrar.installHandlerCalls == 0, "Inactive startup should not install a hotkey handler.")
    }

    private static func testRepeatedFinderActivationIsIdempotent() {
        let registrar = MockHotKeyRegistrar()
        let manager = HotKeyManager(registrar: registrar)

        _ = manager.setRegistrationEnabled(true, shortcut: AppConfig.Shortcut.default)
        _ = manager.setRegistrationEnabled(true, shortcut: AppConfig.Shortcut.default)

        expect(registrar.registerCalls == 1, "Repeated Finder activation must not reserve the shortcut twice.")
        expect(registrar.installHandlerCalls == 1, "Repeated Finder activation must not install duplicate handlers.")
        expect(registrar.unregisterCalls == 0, "An unchanged active shortcut should remain registered.")
    }

    private static func testFinderDeactivationReleasesOnlyHotKey() {
        let registrar = MockHotKeyRegistrar()
        let manager = HotKeyManager(registrar: registrar)

        _ = manager.setRegistrationEnabled(true, shortcut: AppConfig.Shortcut.default)
        _ = manager.setRegistrationEnabled(false, shortcut: AppConfig.Shortcut.default)

        expect(registrar.unregisterCalls == 1, "Finder deactivation must release the global shortcut immediately.")
        expect(registrar.removeHandlerCalls == 0, "Finder deactivation should keep the reusable event handler installed.")
    }

    private static func testReturningToFinderReusesInstalledHandler() {
        let registrar = MockHotKeyRegistrar()
        let manager = HotKeyManager(registrar: registrar)

        _ = manager.setRegistrationEnabled(true, shortcut: AppConfig.Shortcut.default)
        _ = manager.setRegistrationEnabled(false, shortcut: AppConfig.Shortcut.default)
        _ = manager.setRegistrationEnabled(true, shortcut: AppConfig.Shortcut.default)

        expect(registrar.registerCalls == 2, "Returning to Finder should reserve the shortcut again.")
        expect(registrar.unregisterCalls == 1, "Only the Finder deactivation should release the shortcut.")
        expect(registrar.installHandlerCalls == 1, "Returning to Finder should reuse the existing event handler.")
    }

    private static func decodeShortcut(from json: String) -> AppConfig.Shortcut {
        let data = Data(json.utf8)
        return tryOrFail("Expected shortcut decoding to succeed for \(json).") {
            try JSONDecoder().decode(AppConfig.Shortcut.self, from: data)
        }
    }

    private static func tryOrFail<T>(_ message: String, operation: () throws -> T) -> T {
        do {
            return try operation()
        } catch {
            fputs("FAIL: \(message) \(error)\n", stderr)
            exit(1)
        }
    }
}

/// Changes key-window status without showing a window or stealing desktop focus.
@MainActor
private final class ShortcutRecorderTestWindow: NSWindow {
    var reportsKeyWindow = true
    override var isKeyWindow: Bool { reportsKeyWindow }
}

/// A focusable control used to observe Tab traversal.
@MainActor
private final class FocusProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}

@MainActor
private final class ActionProbe: NSObject {
    var count = 0

    @objc func recordAction(_ sender: Any?) {
        count += 1
    }
}

/// Stands in for the responder chain above the recorder.
@MainActor
private final class KeyDownProbe: NSResponder {
    var keyCodes: [UInt16] = []

    override func keyDown(with event: NSEvent) {
        keyCodes.append(event.keyCode)
    }
}

/// A scripted Finder: tests choose the clock, frontmost state, and window, and
/// finish each asynchronous read explicitly.
private final class ScriptedFinderEnvironment: FinderTrackingEnvironment {
    static let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

    var now = Date(timeIntervalSinceReferenceDate: 1_000)
    var isFinderFrontmost = true
    var window: FinderCGWindowInfo? = ScriptedFinderEnvironment.window(number: 42)
    let observesSystemEvents = false
    private(set) var startedReadCount = 0
    private var pendingReads: [@Sendable (FinderState?) -> Void] = []

    var pendingReadCount: Int {
        pendingReads.count
    }

    static func window(number: Int) -> FinderCGWindowInfo {
        FinderCGWindowInfo(number: number, title: nil, layer: 0, alpha: 1, frame: frame)
    }

    func frontmostFinderWindow() -> FinderCGWindowInfo? {
        window
    }

    func readFinderState(_ completion: @escaping @Sendable (FinderState?) -> Void) {
        startedReadCount += 1
        pendingReads.append(completion)
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    /// Finishes the oldest outstanding read after `latency`; `nil` is a failure.
    func finishRead(with state: FinderState?, after latency: TimeInterval = 0) {
        advance(latency)
        pendingReads.removeFirst()(state)
    }
}

/// Runs the production `FinderWindowTracker` against `ScriptedFinderEnvironment`.
private final class TrackerHarness {
    let finder = ScriptedFinderEnvironment()
    let tracker: FinderWindowTracker
    private(set) var updates: [FinderWindowTrackerUpdate] = []

    init() {
        tracker = FinderWindowTracker(config: .default, environment: finder)
        tracker.onUpdate = { [unowned self] update in
            self.updates.append(update)
        }
    }

    /// Starts tracking window 42 and lets its first read finish.
    static func showing(_ state: FinderState) -> TrackerHarness {
        let harness = TrackerHarness()
        harness.tracker.start()
        harness.finder.finishRead(with: state, after: 0.05)
        return harness
    }

    var didShowUnavailablePlaceholder: Bool {
        updates.contains { update in
            guard case .snapshot(let snapshot) = update else { return false }
            return snapshot.state == nil
        }
    }

    /// Mirrors how `AppCoordinator` forwards snapshots to the view model.
    @MainActor
    func applyLastSnapshot(to viewModel: PathBarViewModel) {
        guard case .snapshot(let snapshot) = updates.last else { return }
        viewModel.update(state: snapshot.state, displayMode: .text)
    }
}

/// Runs `SettingsSaveTransaction` with a mock registrar, login item, and disk.
@MainActor
private final class SettingsSaveHarness {
    let registrar: MockHotKeyRegistrar
    let manager: HotKeyManager
    private let finderIsFrontmost: Bool
    private let failsToSave: Bool
    private let failsToRestoreLogin: Bool
    private let failingConfigSaveCalls: Set<Int>
    private var configSaveCalls = 0
    private(set) var loginChanges: [Bool] = []
    private(set) var loginIsEnabled = false
    private(set) var savedConfigs: [AppConfig] = []

    init(
        finderIsFrontmost: Bool,
        rejectedKeyCodes: Set<UInt32> = [],
        failsToSave: Bool = false,
        failsToRestoreLogin: Bool = false,
        failingConfigSaveCalls: Set<Int> = []
    ) {
        registrar = MockHotKeyRegistrar(rejectedKeyCodes: rejectedKeyCodes)
        manager = HotKeyManager(registrar: registrar)
        self.finderIsFrontmost = finderIsFrontmost
        self.failsToSave = failsToSave
        self.failsToRestoreLogin = failsToRestoreLogin
        self.failingConfigSaveCalls = failingConfigSaveCalls
    }

    func save(shortcut: AppConfig.Shortcut, launchAtLogin: Bool) -> SettingsSaveOutcome {
        let finderIsFrontmost = finderIsFrontmost
        let transaction = SettingsSaveTransaction(
            hotKeyManager: manager,
            isFinderFrontmost: { finderIsFrontmost },
            setLaunchAtLogin: { [unowned self] isEnabled in
                self.loginChanges.append(isEnabled)
                if !isEnabled && self.failsToRestoreLogin {
                    throw CocoaError(.fileWriteNoPermission)
                }
                self.loginIsEnabled = isEnabled
            },
            saveConfig: { [unowned self] config in
                self.configSaveCalls += 1
                if self.failsToSave || self.failingConfigSaveCalls.contains(self.configSaveCalls) {
                    throw CocoaError(.fileWriteNoPermission)
                }
                self.savedConfigs.append(config)
            }
        )
        let draft = AppSettingsDraft(launchAtLogin: launchAtLogin, shortcut: shortcut, displayMode: .breadcrumb)
        return transaction.apply(draft, to: .default, launchAtLoginWasEnabled: false)
    }
}

private extension SettingsSaveOutcome {
    var rejectionMessage: String? {
        guard case .rejected(let message) = self else { return nil }
        return message
    }

    var savedShortcut: AppConfig.Shortcut? {
        guard case .saved(let config) = self else { return nil }
        return config.shortcut
    }
}

private final class MockFinderAutomationService: FinderAutomationServing, @unchecked Sendable {
    func currentState() -> FinderState? {
        nil
    }

    func navigate(to path: String, windowID: Int?) -> Bool {
        true
    }
}

private final class RecordingFinderAutomationService: FinderAutomationServing, @unchecked Sendable {
    var navigateRequests: [(path: String, windowID: Int?)] = []

    func currentState() -> FinderState? {
        nil
    }

    func navigate(to path: String, windowID: Int?) -> Bool {
        navigateRequests.append((path, windowID))
        return true
    }
}

private final class MockAppleScriptExecutor: AppleScriptExecuting {
    let result: NSAppleEventDescriptor
    let error: NSDictionary?
    var executeCalls = 0
    var lastScriptSource: String?

    init(result: NSAppleEventDescriptor, error: NSDictionary? = nil) {
        self.result = result
        self.error = error
    }

    func execute(_ script: NSAppleScript, errorInfo: inout NSDictionary?) -> NSAppleEventDescriptor {
        executeCalls += 1
        lastScriptSource = script.source
        errorInfo = error
        return result
    }
}

private final class MockHotKeyRegistrar: HotKeyRegistering {
    let registerStatus: OSStatus
    let installHandlerStatus: OSStatus
    let rejectedKeyCodes: Set<UInt32>
    var registerCalls = 0
    var installHandlerCalls = 0
    var unregisterCalls = 0
    var removeHandlerCalls = 0
    var registrationStatusesByKey: [UInt32: [OSStatus]] = [:]
    /// Key codes currently reserved, so tests can prove nothing is left registered.
    private(set) var activeKeyCodes: Set<UInt32> = []

    init(registerStatus: OSStatus = noErr, installHandlerStatus: OSStatus = noErr, rejectedKeyCodes: Set<UInt32> = []) {
        self.registerStatus = registerStatus
        self.installHandlerStatus = installHandlerStatus
        self.rejectedKeyCodes = rejectedKeyCodes
    }

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyID: EventHotKeyID,
        target: EventTargetRef?,
        hotKeyRef: UnsafeMutablePointer<EventHotKeyRef?>
    ) -> OSStatus {
        registerCalls += 1
        let status: OSStatus
        if var statuses = registrationStatusesByKey[keyCode], !statuses.isEmpty {
            status = statuses.removeFirst()
            registrationStatusesByKey[keyCode] = statuses
        } else {
            status = rejectedKeyCodes.contains(keyCode) ? OSStatus(eventHotKeyExistsErr) : registerStatus
        }
        if status == noErr {
            // Encode the key code in the fake reference so unregister can find it.
            hotKeyRef.pointee = OpaquePointer(bitPattern: Int(keyCode) + 1)
            activeKeyCodes.insert(keyCode)
        }
        return status
    }

    func installHandler(
        target: EventTargetRef?,
        handler: EventHandlerUPP,
        eventSpec: UnsafePointer<EventTypeSpec>,
        userData: UnsafeMutableRawPointer?,
        eventHandlerRef: UnsafeMutablePointer<EventHandlerRef?>
    ) -> OSStatus {
        installHandlerCalls += 1
        if installHandlerStatus == noErr {
            eventHandlerRef.pointee = OpaquePointer(bitPattern: 2)
        }
        return installHandlerStatus
    }

    func unregister(_ hotKeyRef: EventHotKeyRef) -> OSStatus {
        unregisterCalls += 1
        activeKeyCodes.remove(UInt32(Int(bitPattern: hotKeyRef) - 1))
        return noErr
    }

    func removeHandler(_ eventHandlerRef: EventHandlerRef) -> OSStatus {
        removeHandlerCalls += 1
        return noErr
    }
}
