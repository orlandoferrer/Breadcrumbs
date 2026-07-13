import AppKit
import Carbon
import SwiftUI

/// Editable settings are copied into a draft so Cancel can discard changes.
struct AppSettingsDraft {
    var launchAtLogin: Bool
    var shortcut: AppConfig.Shortcut
    var displayMode: AppConfig.DisplayMode
}

@MainActor
/// Owns the reusable AppKit window that hosts the SwiftUI settings form.
final class SettingsWindowController {
    private var window: NSWindow?

    func show(
        draft: AppSettingsDraft,
        onSave: @escaping (AppSettingsDraft) -> String?,
        onCancel: @escaping () -> Void
    ) {
        let view = SettingsView(
            initialDraft: draft,
            onSave: { [weak self] draft in
                if let message = onSave(draft) {
                    return message
                }
                self?.window?.close()
                return nil
            },
            onCancel: { [weak self] in
                onCancel()
                self?.window?.close()
            }
        )

        if let window {
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "FinderBreadcrumbs Settings"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @State private var draft: AppSettingsDraft
    @State private var validationMessage: String?

    let onSave: (AppSettingsDraft) -> String?
    let onCancel: () -> Void

    init(
        initialDraft: AppSettingsDraft,
        onSave: @escaping (AppSettingsDraft) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self._draft = State(initialValue: initialDraft)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Enable at login", isOn: $draft.launchAtLogin)

            VStack(alignment: .leading, spacing: 6) {
                Text("Keyboard shortcut")
                    .font(.headline)
                ShortcutRecorderField(shortcut: $draft.shortcut)
                    .frame(width: 180, height: 28)
                Text("Click the field, then press a key combination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Text display")
                    .font(.headline)
                Picker("Text display", selection: $draft.displayMode) {
                    Text("Plain Text Path").tag(AppConfig.DisplayMode.text)
                    Text("Breadcrumb").tag(AppConfig.DisplayMode.breadcrumb)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    validationMessage = onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420, height: 260)
    }
}

/// SwiftUI wrapper around an AppKit view that receives raw key events.
private struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var shortcut: AppConfig.Shortcut

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onShortcut = { shortcut in
            self.shortcut = shortcut
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.shortcutDescription = shortcut.description
        nsView.onShortcut = { shortcut in
            self.shortcut = shortcut
        }
    }
}

/// Captures one key plus any Command, Option, Control, or Shift modifiers and
/// translates AppKit modifier flags into Carbon's hotkey representation.
private final class ShortcutRecorderView: NSView {
    var onShortcut: ((AppConfig.Shortcut) -> Void)?
    var shortcutDescription: String = "" {
        didSet {
            guard !isRecording else { return }
            label.stringValue = shortcutDescription
        }
    }

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false {
        didSet {
            label.stringValue = isRecording ? "Press shortcut" : shortcutDescription
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        recordShortcut(from: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        recordShortcut(from: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let isFocused = window?.firstResponder === self
        let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)

        NSColor.textBackgroundColor.setFill()
        path.fill()

        if isFocused {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            path.lineWidth = 2
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }
        path.stroke()
    }

    private func recordShortcut(from event: NSEvent) {
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }

        let shortcut = AppConfig.Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        shortcutDescription = shortcut.description
        onShortcut?(shortcut)
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        let deviceFlags = flags.intersection(.deviceIndependentFlagsMask)

        if deviceFlags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if deviceFlags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if deviceFlags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if deviceFlags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }

        return modifiers
    }
}
