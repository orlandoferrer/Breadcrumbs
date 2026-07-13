import SwiftUI

/// SwiftUI content hosted inside the borderless companion panel.
struct PathBarView: View {
    @ObservedObject var viewModel: PathBarViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.995))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 1)
                )

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                HStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            viewModel.isEditing
                                ? Color.accentColor
                                : Color(nsColor: .secondaryLabelColor)
                        )
                        .frame(width: 14)

                    Group {
                        if viewModel.isEditing {
                            PathEditorField(
                                text: $viewModel.editingText,
                                focusRequestID: viewModel.editingSessionID,
                                onCommit: { viewModel.commitEditing() },
                                onCancel: { viewModel.cancelEditing() },
                                onTabComplete: { viewModel.applyUnambiguousCompletion() }
                            )
                            .frame(minWidth: 260)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1)
                            )
                            .shadow(color: Color.accentColor.opacity(0.14), radius: 5, x: 0, y: 1)
                        } else {
                            ReadOnlyPathContent(viewModel: viewModel)
                        }
                    }
                }
                .frame(maxWidth: 540, alignment: .center)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .padding(.horizontal, 1)
        .padding(.vertical, 1)
    }
}

private struct ReadOnlyPathContent: View {
    @ObservedObject var viewModel: PathBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if viewModel.displayMode == .breadcrumb, let segments = breadcrumbSegments {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            HStack(spacing: 4) {
                                Text(segment)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(primaryTextColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                    )

                                if index < segments.count - 1 {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                }
                            }
                        }
                    }
                }
            } else {
                Text(viewModel.displayedText)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if case let .unavailable(message) = viewModel.status {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var breadcrumbSegments: [String]? {
        guard case .ready = viewModel.status else { return nil }
        let segments = viewModel.displayedText
            .split(separator: "/")
            .map(String.init)
        return segments.isEmpty ? nil : segments
    }

    private var primaryTextColor: Color {
        Color(nsColor: .labelColor)
    }
}

/// Pure caret-position logic kept separate so it can be regression tested.
enum EditingCursorPlacement {
    @MainActor
    static func endInsertionIndex(for field: NSTextField) -> Int {
        (field.stringValue as NSString).length
    }
}

/// Handles AppKit's shared field editor and places the insertion caret at the
/// end of the path when a new edit session starts.
enum PathEditorActivation {
    @MainActor
    @discardableResult
    static func activateEditing(in field: NSTextField, window: NSWindow) -> Bool {
        window.makeKeyAndOrderFront(nil)

        if let editor = field.currentEditor() as? NSTextView {
            placeCaretAtEnd(in: editor, for: field)
            return true
        }

        field.selectText(nil)
        if let editor = field.currentEditor() as? NSTextView {
            placeCaretAtEnd(in: editor, for: field)
            return true
        }

        window.makeFirstResponder(field)
        if let editor = window.fieldEditor(true, for: field) as? NSTextView {
            window.makeFirstResponder(editor)
            placeCaretAtEnd(in: editor, for: field)
            return true
        }

        return false
    }

    @MainActor
    static func placeCaretAtEnd(in editor: NSTextView, for field: NSTextField) {
        editor.insertionPointColor = .labelColor
        editor.drawsBackground = false
        editor.selectedRange = NSRange(location: EditingCursorPlacement.endInsertionIndex(for: field), length: 0)
    }
}

/// Bridges SwiftUI bindings to `NSTextField`, whose AppKit field-editor behavior
/// provides more reliable one-click editing than SwiftUI's `TextField` here.
private struct PathEditorField: NSViewRepresentable {
    @Binding var text: String
    let focusRequestID: Int
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onTabComplete: () -> Void

    func makeNSView(context: Context) -> KeyAwareTextField {
        let field = KeyAwareTextField()
        field.isBordered = false
        field.isEditable = true
        field.isSelectable = true
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5, weight: .regular)
        field.textColor = .controlTextColor
        field.delegate = context.coordinator
        context.coordinator.configureHandlers(
            onCommit: onCommit,
            onCancel: onCancel,
            onTabComplete: onTabComplete
        )
        context.coordinator.scheduleInitialFocus(for: field, focusRequestID: focusRequestID)
        return field
    }

    func updateNSView(_ nsView: KeyAwareTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.configureHandlers(
            onCommit: onCommit,
            onCancel: onCancel,
            onTabComplete: onTabComplete
        )
        context.coordinator.scheduleInitialFocus(for: nsView, focusRequestID: focusRequestID)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        private var onCommit: (() -> Void)?
        private var onCancel: (() -> Void)?
        private var onTabComplete: (() -> Void)?

        init(text: Binding<String>) {
            _text = text
        }

        func configureHandlers(
            onCommit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onTabComplete: @escaping () -> Void
        ) {
            self.onCommit = onCommit
            self.onCancel = onCancel
            self.onTabComplete = onTabComplete
        }

        @MainActor
        func scheduleInitialFocus(for field: KeyAwareTextField, focusRequestID: Int) {
            guard field.lastHandledFocusRequestID != focusRequestID,
                  field.pendingFocusRequestID != focusRequestID else { return }
            field.pendingFocusRequestID = focusRequestID
            // SwiftUI may call `makeNSView` before the field belongs to a window.
            // Yielding gives the hosting hierarchy time to attach it.
            Task { @MainActor [weak field] in
                guard let field else { return }
                defer {
                    field.pendingFocusRequestID = nil
                }
                for _ in 0..<3 {
                    await Task.yield()
                    guard let window = field.window else { continue }
                    if PathEditorActivation.activateEditing(in: field, window: window) {
                        field.lastHandledFocusRequestID = focusRequestID
                        return
                    }
                }
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            PathEditorActivation.placeCaretAtEnd(in: editor, for: field)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                onCommit?()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel?()
                return true
            case #selector(NSResponder.insertTab(_:)):
                onTabComplete?()
                return true
            default:
                return false
            }
        }
    }
}

final class KeyAwareTextField: NSTextField {
    var pendingFocusRequestID: Int?
    var lastHandledFocusRequestID: Int?

    override var acceptsFirstResponder: Bool {
        true
    }
}
