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
            testUnavailableUpdateDoesNotCancelEditing()
            testCommitUsesWindowWhereEditSessionBegan()
        }
        testReadableShortcutDecoding()
        testLegacyShortcutDecoding()
        testReadableShortcutEncoding()
        testConfigMissingDiagnosticsFlagUsesDefault()
        testConfigIgnoresRemovedTrackingFlag()
        testConfigSanitizesInvalidPollingIntervals()
        testFinderStateAcceptsFileURLFallback()
        testFinderStateRecoversClassCodedAFPPath()
        testFinderStateScriptProtectsDescriptionCoercion()
        testNavigationAcceptsNonTextAppleScriptResult()
        testFinderStateRefreshCacheThrottlesMotionPolling()
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
    private static func testUnavailableUpdateDoesNotCancelEditing() {
        let viewModel = makeReadyViewModel()
        var returnFocusRequests: [Bool] = []
        viewModel.onEditingEnded = { shouldReturnFocusToFinder in
            returnFocusRequests.append(shouldReturnFocusToFinder)
        }

        expect(viewModel.beginEditing(), "Expected editing to begin with a current Finder state.")
        viewModel.editingText = "/tmp/manual"
        viewModel.update(state: nil, displayMode: .text)

        expect(viewModel.isEditing, "Transient unavailable tracking updates must not cancel an active edit session.")
        expect(viewModel.editingText == "/tmp/manual", "Unavailable updates must not overwrite in-progress edits.")
        expect(returnFocusRequests.isEmpty, "Unavailable updates should not fire editing cleanup callbacks.")
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
                return cache.state
            }
            loadCount += 1
            cache.store(expectedState, refreshedAt: date)
            return cache.state
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

        expect(
            state.begin(isStateRefreshInFlight: false),
            "The first fresh-snapshot request should start a Finder refresh."
        )
        expect(
            !state.begin(isStateRefreshInFlight: true),
            "Repeated hotkey requests must share the active Finder refresh."
        )
        expect(
            state.consumeRetryIfAvailable(finderIsFrontmost: true),
            "A mismatched in-flight result should permit one fresh retry."
        )
        expect(
            !state.consumeRetryIfAvailable(finderIsFrontmost: true),
            "Repeated hotkey presses must not replenish the retry allowance."
        )

        state.finish()
        expect(
            state.begin(isStateRefreshInFlight: false),
            "A completed request should allow the next hotkey press to start a refresh."
        )
        state.finish()

        expect(
            !state.begin(isStateRefreshInFlight: true),
            "A request should attach to a polling refresh that is already in flight."
        )
        expect(state.isActive, "An attached request must remain active until that refresh completes.")
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
        gate.cancel(requestID: timedOutRequest)
        expect(
            gate.consume(
                requestID: latestRequest,
                finderIsFrontmost: true,
                hasFreshSnapshot: true
            ),
            "A stale timeout must not cancel a newer hotkey request."
        )
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
    var executeCalls = 0

    init(result: NSAppleEventDescriptor) {
        self.result = result
    }

    func execute(_ script: NSAppleScript, errorInfo: inout NSDictionary?) -> NSAppleEventDescriptor {
        executeCalls += 1
        errorInfo = nil
        return result
    }
}

private final class MockHotKeyRegistrar: HotKeyRegistering {
    let registerStatus: OSStatus
    let installHandlerStatus: OSStatus
    var registerCalls = 0
    var installHandlerCalls = 0
    var unregisterCalls = 0
    var removeHandlerCalls = 0

    init(registerStatus: OSStatus = noErr, installHandlerStatus: OSStatus = noErr) {
        self.registerStatus = registerStatus
        self.installHandlerStatus = installHandlerStatus
    }

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyID: EventHotKeyID,
        target: EventTargetRef?,
        hotKeyRef: UnsafeMutablePointer<EventHotKeyRef?>
    ) -> OSStatus {
        registerCalls += 1
        if registerStatus == noErr {
            hotKeyRef.pointee = OpaquePointer(bitPattern: 1)
        }
        return registerStatus
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
        return noErr
    }

    func removeHandler(_ eventHandlerRef: EventHandlerRef) -> OSStatus {
        removeHandlerCalls += 1
        return noErr
    }
}
