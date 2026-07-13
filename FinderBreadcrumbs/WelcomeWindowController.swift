import AppKit
import SwiftUI

@MainActor
/// Owns the reusable permissions window and reports dismissal exactly once.
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onDismiss: (() -> Void)?
    private var isDismissing = false

    func show(
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        let view = WelcomeView(
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        if let window {
            install(view, in: window)
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to Breadcrumbs"
            window.isReleasedWhenClosed = false
            window.delegate = self
            install(view, in: window)
            window.center()
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isDismissing else { return }
        completeDismissal()
    }

    private func install(_ view: WelcomeView, in window: NSWindow) {
        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
    }

    private func dismiss() {
        isDismissing = true
        completeDismissal()
        window?.close()
        isDismissing = false
    }

    private func completeDismissal() {
        onDismiss?()
        onDismiss = nil
    }
}

/// Polls permission state while visible because users grant Accessibility in a
/// separate System Settings process.
private struct WelcomeView: View {
    let onDismiss: () -> Void

    @State private var accessibilityState: PermissionState = .unknown
    @State private var automationState: PermissionState = .unknown
    @State private var isRequestingAutomation = false

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Breadcrumbs")
                    .font(.title2.weight(.semibold))
                Text("Breadcrumbs follows Finder windows and lets you jump to folders from a small path bar. macOS requires your permission for both parts to work.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PermissionStatusRow(
                symbolName: "folder",
                title: "Finder automation",
                detail: "Reads the folder shown in Finder and opens folders you type into the path bar.",
                state: automationState,
                deniedAppearance: .notGranted,
                actionTitle: automationActionTitle,
                action: performAutomationAction
            )

            PermissionStatusRow(
                symbolName: "accessibility",
                title: "Accessibility",
                detail: "Tracks the active Finder window so the path bar stays attached while it moves.",
                state: accessibilityState,
                deniedAppearance: .limited,
                actionTitle: accessibilityState == .granted ? nil : "Open System Settings",
                action: { openPrivacyPane("Privacy_Accessibility") }
            )

            HStack {
                Button("Check Again") {
                    refreshStates()
                }

                Spacer()

                Button("Continue", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            refreshStates()
        }
        .onReceive(refreshTimer) { _ in
            refreshStates()
        }
    }

    private var automationActionTitle: String? {
        switch automationState {
        case .granted:
            return nil
        case .denied:
            return "Open System Settings"
        case .notDetermined, .unknown:
            return isRequestingAutomation ? "Requesting…" : "Request Permission"
        }
    }

    private func performAutomationAction() {
        switch automationState {
        case .granted:
            break
        case .denied:
            openPrivacyPane("Privacy_Automation")
        case .notDetermined, .unknown:
            requestAutomationPermission()
        }
    }

    private func requestAutomationPermission() {
        guard !isRequestingAutomation else { return }
        isRequestingAutomation = true
        DispatchQueue.global(qos: .userInitiated).async {
            let state = AutomationPermissionManager.finderAutomationState(promptIfNeeded: true)
            DispatchQueue.main.async {
                isRequestingAutomation = false
                automationState = state
            }
        }
    }

    private func refreshStates() {
        accessibilityState = AccessibilityPermissionManager.state
        if !isRequestingAutomation {
            automationState = AutomationPermissionManager.finderAutomationState()
        }
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct PermissionStatusRow: View {
    let symbolName: String
    let title: String
    let detail: String
    let state: PermissionState
    let deniedAppearance: DeniedPermissionAppearance
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    statusChip
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var statusChip: some View {
        HStack(spacing: 4) {
            Image(systemName: chipSymbolName)
            Text(chipText)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(chipColor)
    }

    private var chipSymbolName: String {
        switch state {
        case .granted:
            return "checkmark.circle.fill"
        case .denied:
            return deniedAppearance.symbolName
        case .notDetermined:
            return "questionmark.circle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var chipText: String {
        switch state {
        case .granted:
            return "Granted"
        case .denied:
            return deniedAppearance.text
        case .notDetermined:
            return "Not requested yet"
        case .unknown:
            return "Unknown"
        }
    }

    private var chipColor: Color {
        switch state {
        case .granted:
            return .green
        case .denied:
            return deniedAppearance.color
        case .notDetermined:
            return .orange
        case .unknown:
            return .secondary
        }
    }
}

private enum DeniedPermissionAppearance {
    case notGranted
    case limited

    var symbolName: String {
        switch self {
        case .notGranted:
            return "xmark.circle.fill"
        case .limited:
            return "exclamationmark.circle.fill"
        }
    }

    var text: String {
        switch self {
        case .notGranted:
            return "Not granted"
        case .limited:
            return "Limited"
        }
    }

    var color: Color {
        switch self {
        case .notGranted:
            return .red
        case .limited:
            return .orange
        }
    }
}
