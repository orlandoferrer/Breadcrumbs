import Carbon
import Foundation

@main
struct EditingFocusRegressionTests {
    static func main() async {
        await MainActor.run {
            testOutsideClickCancelDoesNotReturnFocusToFinder()
            testCommitStillReturnsFocusToFinder()
        }
        testReadableShortcutDecoding()
        testLegacyShortcutDecoding()
        testReadableShortcutEncoding()
        testConfigMissingDiagnosticsFlagUsesDefault()
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
              "trackOnlyFrontmostFinderWindow": true,
              "verticalGap": -6
            }
            """.utf8))
        }

        expect(
            config.debugLogFinderWindowDiagnostics == false,
            "Older config files should keep diagnostics disabled by default."
        )
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
