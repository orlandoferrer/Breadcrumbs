import AppKit
import Carbon
import Foundation

@main
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
        testHotKeyRegistrationReturnsRegisterFailure()
        testHotKeyRegistrationReturnsHandlerFailureAndCleansUp()
        testHotKeyRegistrationSuccessInstallsHandler()
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
        expect(encoded == #""cmd+option+l""#, "Expected shortcut encoding to use readable config strings.")
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

        expect(config.shortcut == .default, "Legacy configs with removed keys should still decode normally.")
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

private final class MockFinderAutomationService: FinderAutomationServing {
    func currentState() -> FinderState? {
        nil
    }

    func navigate(to path: String, windowID: Int?) -> Bool {
        true
    }

    func hasAutomationPermission() -> Bool {
        true
    }

    func requestAutomationPermission() -> Bool {
        true
    }
}

private final class RecordingFinderAutomationService: FinderAutomationServing {
    var navigateRequests: [(path: String, windowID: Int?)] = []

    func currentState() -> FinderState? {
        nil
    }

    func navigate(to path: String, windowID: Int?) -> Bool {
        navigateRequests.append((path, windowID))
        return true
    }

    func hasAutomationPermission() -> Bool {
        true
    }

    func requestAutomationPermission() -> Bool {
        true
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
