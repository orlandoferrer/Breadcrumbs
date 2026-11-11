import AppKit
import Carbon
import SwiftUI

/// Editable settings are copied into a draft so Cancel can discard changes.
struct AppSettingsDraft {
    var launchAtLogin: Bool
    var shortcut: AppConfig.Shortcut
    var displayMode: AppConfig.DisplayMode
}

enum SettingsSaveOutcome {
    case saved(AppConfig)
    /// Save failed; the message also identifies any changes recovery could not undo.
    case rejected(String)
}

/// Applies a Settings draft with checked registration and explicit recovery errors.
///
/// Save runs while Breadcrumbs, not Finder, is frontmost. The new shortcut is
/// registered only long enough to prove that macOS accepts it, then the normal
/// Finder-only registration is restored before any other side effect. Enable at
/// login therefore never changes for an invalid or conflicting shortcut, and no
/// shortcut stays reserved while another app is frontmost.
@MainActor
struct SettingsSaveTransaction {
    let hotKeyManager: HotKeyManager
    var isFinderFrontmost: () -> Bool
    var setLaunchAtLogin: (Bool) throws -> Void
    var saveConfig: (AppConfig) throws -> Void

    func apply(
        _ draft: AppSettingsDraft,
        to config: AppConfig,
        launchAtLoginWasEnabled: Bool
    ) -> SettingsSaveOutcome {
        if let problem = draft.shortcut.validationProblem {
            return .rejected("Keyboard shortcut \(draft.shortcut.description) is not allowed. \(problem)")
        }

        let registrationStatus = hotKeyManager.register(shortcut: draft.shortcut)
        guard registrationStatus == noErr else {
            return reject(
                "Could not register keyboard shortcut \(draft.shortcut.description). "
                    + "Another app may already use it (OSStatus \(registrationStatus)).",
                restoring: config,
                launchAtLoginWasEnabled: launchAtLoginWasEnabled
            )
        }
        let restorationStatus = syncRegistration(of: config.shortcut)
        guard restorationStatus == noErr else {
            return reject(
                "Could not restore keyboard shortcut \(config.shortcut.description) after validation "
                    + "(OSStatus \(restorationStatus)).",
                restoring: config,
                launchAtLoginWasEnabled: launchAtLoginWasEnabled
            )
        }

        let changesLaunchAtLogin = draft.launchAtLogin != launchAtLoginWasEnabled
        if changesLaunchAtLogin {
            do {
                try setLaunchAtLogin(draft.launchAtLogin)
            } catch {
                return reject(
                    "Could not update Enable at login: \(error.localizedDescription)",
                    restoring: config,
                    launchAtLoginWasEnabled: launchAtLoginWasEnabled,
                    restoreLogin: true
                )
            }
        }

        var updatedConfig = config
        updatedConfig.launchAtLogin = draft.launchAtLogin
        updatedConfig.shortcut = draft.shortcut
        updatedConfig.displayMode = draft.displayMode
        do {
            try saveConfig(updatedConfig)
        } catch {
            return reject(
                "Could not save settings: \(error.localizedDescription)",
                restoring: config,
                launchAtLoginWasEnabled: launchAtLoginWasEnabled,
                restoreLogin: changesLaunchAtLogin
            )
        }

        let activationStatus = syncRegistration(of: updatedConfig.shortcut)
        guard activationStatus == noErr else {
            // The probe was released before persistence. Another app can reserve
            // the shortcut meanwhile, so final activation is also part of Save.
            return reject(
                "Could not register keyboard shortcut \(updatedConfig.shortcut.description) "
                    + "after saving (OSStatus \(activationStatus)).",
                restoring: config,
                launchAtLoginWasEnabled: launchAtLoginWasEnabled,
                restoreLogin: changesLaunchAtLogin,
                restoreConfig: true
            )
        }
        return .saved(updatedConfig)
    }

    /// Recovery is best effort across system services and disk. Attempt every
    /// restoration even if another one fails, and never hide a partial change.
    private func reject(
        _ message: String,
        restoring config: AppConfig,
        launchAtLoginWasEnabled: Bool,
        restoreLogin: Bool = false,
        restoreConfig: Bool = false
    ) -> SettingsSaveOutcome {
        var recoveryFailures: [String] = []
        if restoreConfig {
            do {
                try saveConfig(config)
            } catch {
                recoveryFailures.append("Could not restore the previous configuration: \(error.localizedDescription)")
            }
        }
        if restoreLogin {
            do {
                try setLaunchAtLogin(launchAtLoginWasEnabled)
            } catch {
                recoveryFailures.append(
                    "Could not restore Enable at login: \(error.localizedDescription) "
                        + "Check Login Items in System Settings."
                )
            }
        }
        let status = syncRegistration(of: config.shortcut)
        if status != noErr {
            recoveryFailures.append("Could not restore keyboard shortcut \(config.shortcut.description) (OSStatus \(status)).")
        }
        guard !recoveryFailures.isEmpty else { return .rejected(message) }
        return .rejected(message + " Some changes could not be undone. " + recoveryFailures.joined(separator: " "))
    }

    /// Reserves `shortcut` only while Finder is frontmost, as in normal use.
    private func syncRegistration(of shortcut: AppConfig.Shortcut) -> OSStatus {
        hotKeyManager.setRegistrationEnabled(isFinderFrontmost(), shortcut: shortcut)
    }
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
                Text("Click the field, then press a combination with Command or Control. Esc cancels.")
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
///
/// Recording starts only from a click (or Space while focused), and only while
/// the view is first responder in the key window. Opening Settings or receiving
/// initial focus never captures keys. While recording, Escape cancels, Tab and
/// Shift-Tab move focus, and Return falls through to the default button.
final class ShortcutRecorderView: NSView {
    var onShortcut: ((AppConfig.Shortcut) -> Void)?
    /// Called when a combination fails `Shortcut.validationProblem`.
    var onRejectedShortcut: () -> Void = { NSSound.beep() }
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
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
    }

    override func becomeFirstResponder() -> Bool {
        // Focus alone, such as initial focus or Tab, does not start recording.
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        if let window {
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        if let newWindow {
            center.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: newWindow
            )
        }
    }

    /// Switching to another window or app abandons the recording session.
    @objc private func windowDidResignKey(_ notification: Notification) {
        isRecording = false
    }

    private var canRecordShortcut: Bool {
        isRecording && window?.isKeyWindow == true && window?.firstResponder === self
    }

    /// Keys that keep their usual meaning instead of becoming the shortcut.
    private enum RecordingKeyRole {
        case cancel
        case focusNext
        case focusPrevious
        case defaultAction
        case shortcut
    }

    private static func recordingRole(of event: NSEvent) -> RecordingKeyRole {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers == 0:
            return .cancel
        case kVK_Tab where modifiers == 0:
            return .focusNext
        case kVK_Tab where modifiers == UInt32(shiftKey):
            return .focusPrevious
        case kVK_Return where modifiers == 0, kVK_ANSI_KeypadEnter where modifiers == 0:
            return .defaultAction
        default:
            return .shortcut
        }
    }

    override func keyDown(with event: NSEvent) {
        guard canRecordShortcut else {
            if window?.isKeyWindow == true, window?.firstResponder === self,
               event.keyCode == UInt16(kVK_Space),
               Self.carbonModifiers(from: event.modifierFlags) == 0 {
                // Space starts recording from the keyboard, like pressing a button.
                isRecording = true
                return
            }
            super.keyDown(with: event)
            return
        }

        switch Self.recordingRole(of: event) {
        case .cancel:
            isRecording = false
        case .focusNext:
            isRecording = false
            window?.selectKeyView(following: self)
        case .focusPrevious:
            isRecording = false
            window?.selectKeyView(preceding: self)
        case .defaultAction:
            isRecording = false
            // Let the responder chain reach the window default button.
            super.keyDown(with: event)
        case .shortcut:
            recordShortcut(from: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers key equivalents to unfocused views as well.
        guard canRecordShortcut else {
            return super.performKeyEquivalent(with: event)
        }

        switch Self.recordingRole(of: event) {
        case .cancel:
            // Consume Escape so it cancels recording, not the Settings window.
            isRecording = false
            return true
        case .focusNext, .focusPrevious:
            // AppKit follows up with keyDown, which moves focus.
            return false
        case .defaultAction:
            isRecording = false
            return super.performKeyEquivalent(with: event)
        case .shortcut:
            recordShortcut(from: event)
            return true
        }
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
        let shortcut = AppConfig.Shortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: Self.carbonModifiers(from: event.modifierFlags)
        )
        // Config loading uses the same policy. Keep recording after a rejected
        // combination such as Shift-A so the user can try another one.
        guard shortcut.validationProblem == nil else {
            onRejectedShortcut()
            return
        }

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
