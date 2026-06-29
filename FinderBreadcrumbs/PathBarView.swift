import SwiftUI

struct PathBarView: View {
    @ObservedObject var viewModel: PathBarViewModel
    let onActivateEditing: () -> Void

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
        .onTapGesture {
            if !viewModel.isEditing {
                onActivateEditing()
            }
        }
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
        let text = viewModel.displayedText
        guard text != "Finder detected, but the path is unavailable" else { return nil }
        return text
            .split(separator: "/")
            .map(String.init)
    }

    private var primaryTextColor: Color {
        Color(nsColor: .labelColor)
    }
}

private struct PathEditorField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onTabComplete: () -> Void

    func makeNSView(context: Context) -> KeyAwareTextField {
        let field = KeyAwareTextField()
        field.isBordered = false
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
        context.coordinator.scheduleInitialFocus(for: field)
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
        context.coordinator.scheduleInitialFocus(for: nsView)
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
        func scheduleInitialFocus(for field: KeyAwareTextField) {
            guard !field.didScheduleInitialFocus else { return }
            field.didScheduleInitialFocus = true
            Task { @MainActor [weak field] in
                guard let field else { return }
                await Task.yield()
                guard let window = field.window else {
                    field.didScheduleInitialFocus = false
                    return
                }

                window.makeFirstResponder(field)
                if let editor = window.fieldEditor(true, for: field) as? NSTextView {
                    editor.insertionPointColor = .labelColor
                    editor.drawsBackground = false
                    editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
                }
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            editor.insertionPointColor = .labelColor
            editor.drawsBackground = false
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
    var didScheduleInitialFocus = false
}
