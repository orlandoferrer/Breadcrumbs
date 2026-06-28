import AppKit
import Foundation

@MainActor
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

        if isEditing, let previousState, previousState != state {
            isEditing = false
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
        isEditing = true
        return true
    }

    func cancelEditing(returnFocusToFinder: Bool = true) {
        isEditing = false
        if let currentState {
            editingText = currentState.resolvedPath
        }
        onEditingEnded?(returnFocusToFinder)
    }

    func commitEditing() {
        let candidate = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            cancelEditing()
            return
        }

        let autocompleted = completePathIfUnambiguous(candidate) ?? candidate
        if automationService.navigate(to: autocompleted, windowID: currentState?.windowID) {
            isEditing = false
            editingText = autocompleted
            if var currentState {
                currentState = FinderState(
                    displayedPath: autocompleted,
                    resolvedPath: autocompleted,
                    windowID: currentState.windowID
                )
                self.currentState = currentState
                displayedText = formatDisplayText(for: currentState)
            }
            onEditingEnded?(true)
        }
    }

    func applyUnambiguousCompletion() {
        guard let completion = completePathIfUnambiguous(editingText) else { return }
        editingText = completion
    }

    private func formatDisplayText(for state: FinderState) -> String {
        switch displayMode {
        case .text:
            return state.resolvedPath
        case .breadcrumb:
            let components = state.resolvedPath.split(separator: "/").map(String.init)
            return "/" + components.joined(separator: " / ")
        }
    }

    private func completePathIfUnambiguous(_ rawInput: String) -> String? {
        let input = NSString(string: rawInput).expandingTildeInPath
        let hasTrailingSlash = input.hasSuffix("/")
        let nsInput = input as NSString
        let directoryPart = hasTrailingSlash ? input : nsInput.deletingLastPathComponent
        let fragment = hasTrailingSlash ? "" : nsInput.lastPathComponent
        let searchDirectory = directoryPart.isEmpty ? "/" : directoryPart

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: searchDirectory) else {
            return nil
        }

        let matches = entries
            .filter { $0.hasPrefix(fragment) }
            .sorted()

        guard matches.count == 1 else {
            return nil
        }

        return URL(fileURLWithPath: searchDirectory)
            .appendingPathComponent(matches[0], isDirectory: true)
            .path
    }
}
