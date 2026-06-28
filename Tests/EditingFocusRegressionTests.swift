import Foundation

@main
struct EditingFocusRegressionTests {
    static func main() async {
        await MainActor.run {
            testOutsideClickCancelDoesNotReturnFocusToFinder()
            testCommitStillReturnsFocusToFinder()
        }
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
}

private final class MockFinderAutomationService: FinderAutomationServing {
    func currentState() -> FinderState? {
        nil
    }

    func navigate(to path: String, windowID: Int?) -> Bool {
        true
    }
}
