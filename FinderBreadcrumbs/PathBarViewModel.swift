import AppKit
import Foundation

@MainActor
/// Presentation and editing state shared by the SwiftUI path bar.
///
/// The view model contains no window-positioning logic. It translates Finder
/// state into display text and turns editing actions into navigation requests.
final class PathBarViewModel: ObservableObject {
    enum Status {
        case ready
        case unavailable(String)
    }

    @Published var displayedText = ""
    @Published var editingText = ""
    @Published var isEditing = false
    @Published var displayMode: AppConfig.DisplayMode
    @Published var status: Status = .unavailable("Waiting for Finder")

    var onEditingEnded: ((Bool) -> Void)?

    private let automationService: FinderAutomationServing
    private(set) var currentState: FinderState?
    private(set) var editingSessionID = 0
    private(set) var editingWindowID: Int?

    init(displayMode: AppConfig.DisplayMode, automationService: FinderAutomationServing) {
        self.displayMode = displayMode
        self.automationService = automationService
    }

    func update(state: FinderState?, displayMode: AppConfig.DisplayMode) {
        self.displayMode = displayMode

        guard let state else {
            status = .unavailable("Unsupported Finder location")
            if currentState == nil && !isEditing {
                displayedText = "Unsupported Finder location"
            }
            return
        }

        let previousState = currentState
        currentState = state
        status = .ready

        // A tab/window change invalidates the edit session. Continuing would risk
        // navigating a Finder window other than the one the user now sees.
        if isEditing, let previousState, previousState != state {
            endEditingSession(returnFocusToFinder: false, resetEditingTextFromCurrentState: false)
        }

        if !isEditing {
            editingText = state.resolvedPath
        }

        displayedText = formatDisplayText(for: state)
    }

    @discardableResult
    func beginEditing() -> Bool {
        guard let currentState else { return false }
        editingText = currentState.resolvedPath
        editingWindowID = currentState.windowID
        editingSessionID += 1
        isEditing = true
        return true
    }

    func cancelEditing(returnFocusToFinder: Bool = true) {
        endEditingSession(returnFocusToFinder: returnFocusToFinder, resetEditingTextFromCurrentState: true)
    }

    func commitEditing() {
        guard isEditing else { return }
        let candidate = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            cancelEditing()
            return
        }

        // Return performs the same conservative completion as Tab, then resolves
        // `~`, `.`/`..`, and symbolic links before Finder sees the path.
        let autocompleted = completePathIfUnambiguous(candidate) ?? candidate
        let normalized = URL(fileURLWithPath: NSString(string: autocompleted).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        if automationService.navigate(to: normalized, windowID: editingWindowID ?? currentState?.windowID) {
            isEditing = false
            editingWindowID = nil
            editingText = normalized
            if var currentState {
                currentState = FinderState(
                    displayedPath: normalized,
                    resolvedPath: normalized,
                    windowID: currentState.windowID
                )
                self.currentState = currentState
                displayedText = formatDisplayText(for: currentState)
            }
            onEditingEnded?(true)
        } else {
            NSSound.beep()
        }
    }

    func applyUnambiguousCompletion() {
        guard let completion = completePathIfUnambiguous(editingText) else { return }
        editingText = completion
    }

    private func formatDisplayText(for state: FinderState) -> String {
        state.resolvedPath
    }

    private func completePathIfUnambiguous(_ rawInput: String) -> String? {
        // Completion is directory-only and succeeds only for exactly one match;
        // this deliberately avoids a suggestion menu and ambiguity state.
        let input = NSString(string: rawInput).expandingTildeInPath
        let hasTrailingSlash = input.hasSuffix("/")
        let nsInput = input as NSString
        let directoryPart = hasTrailingSlash ? input : nsInput.deletingLastPathComponent
        let fragment = hasTrailingSlash ? "" : nsInput.lastPathComponent
        let searchDirectory = directoryPart.isEmpty ? "/" : directoryPart

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: searchDirectory) else {
            return nil
        }

        let loweredFragment = fragment.lowercased()
        let matches = entries.filter { entry in
            guard entry.lowercased().hasPrefix(loweredFragment) else { return false }
            var isDirectory: ObjCBool = false
            let candidatePath = NSString(string: searchDirectory).appendingPathComponent(entry)
            return FileManager.default.fileExists(atPath: candidatePath, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        guard matches.count == 1 else {
            return nil
        }

        return URL(fileURLWithPath: searchDirectory)
            .appendingPathComponent(matches[0], isDirectory: true)
            .path
    }

    private func endEditingSession(
        returnFocusToFinder: Bool,
        resetEditingTextFromCurrentState: Bool
    ) {
        isEditing = false
        editingWindowID = nil
        if resetEditingTextFromCurrentState, let currentState {
            editingText = currentState.resolvedPath
        }
        onEditingEnded?(returnFocusToFinder)
    }
}
