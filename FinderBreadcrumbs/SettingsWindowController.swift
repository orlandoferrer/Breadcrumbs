import AppKit
import Carbon
import SwiftUI

struct AppSettingsDraft {
    var launchAtLogin: Bool
    var shortcut: AppConfig.Shortcut
    var displayMode: AppConfig.DisplayMode
}

@MainActor
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

private struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var shortcut: AppConfig.Shortcut

    func makeNSView(context: Context) -> ShortcutRecorderTextField {
        let field = ShortcutRecorderTextField()
        field.onShortcut = { shortcut in
            self.shortcut = shortcut
        }
        return field
    }

    func updateNSView(_ nsView: ShortcutRecorderTextField, context: Context) {
        nsView.stringValue = shortcut.description
        nsView.onShortcut = { shortcut in
            self.shortcut = shortcut
        }
    }
}

private final class ShortcutRecorderTextField: NSTextField {
    var onShortcut: ((AppConfig.Shortcut) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        focusRingType = .default
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        placeholderString = "Record shortcut"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        recordShortcut(from: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        recordShortcut(from: event)
        return true
    }

    private func recordShortcut(from event: NSEvent) {
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }

        let shortcut = AppConfig.Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        stringValue = shortcut.description
        onShortcut?(shortcut)
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
