import AppKit
import SwiftUI

struct PermissionStatus {
    var accessibilityGranted: Bool
    var finderAccessGranted: Bool

    var isComplete: Bool {
        accessibilityGranted && finderAccessGranted
    }
}

@MainActor
final class PermissionsOnboardingWindowController {
    private var window: NSWindow?

    func show(
        status: PermissionStatus,
        onOpenAccessibility: @escaping () -> Void,
        onAllowFinderAccess: @escaping () -> Void,
        onCheckAgain: @escaping () -> PermissionStatus,
        onDismiss: @escaping () -> Void
    ) {
        let view = PermissionsOnboardingView(
            initialStatus: status,
            onOpenAccessibility: onOpenAccessibility,
            onAllowFinderAccess: onAllowFinderAccess,
            onCheckAgain: onCheckAgain,
            onDismiss: { [weak self] in
                onDismiss()
                self?.window?.close()
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

    private func install(_ view: PermissionsOnboardingView, in window: NSWindow) {
        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
    }
}

private struct PermissionsOnboardingView: View {
    @State private var status: PermissionStatus

    let onOpenAccessibility: () -> Void
    let onAllowFinderAccess: () -> Void
    let onCheckAgain: () -> PermissionStatus
    let onDismiss: () -> Void

    init(
        initialStatus: PermissionStatus,
        onOpenAccessibility: @escaping () -> Void,
        onAllowFinderAccess: @escaping () -> Void,
        onCheckAgain: @escaping () -> PermissionStatus,
        onDismiss: @escaping () -> Void
    ) {
        self._status = State(initialValue: initialStatus)
        self.onOpenAccessibility = onOpenAccessibility
        self.onAllowFinderAccess = onAllowFinderAccess
        self.onCheckAgain = onCheckAgain
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Breadcrumbs")
                    .font(.title2.weight(.semibold))
                Text("Breadcrumbs needs two macOS permissions before it can follow Finder windows and help you jump to folders.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PermissionRow(
                title: "Control Finder",
                detail: "Lets Breadcrumbs read the folder shown in the active Finder window and jump to a folder when you type a path.",
                isGranted: status.finderAccessGranted,
                buttonTitle: "Allow Finder Access"
            ) {
                onAllowFinderAccess()
                status = onCheckAgain()
            }

            PermissionRow(
                title: "Accessibility",
                detail: "Lets Breadcrumbs find the active Finder window and place the path bar in the right spot.",
                isGranted: status.accessibilityGranted,
                buttonTitle: "Open Accessibility Settings"
            ) {
                onOpenAccessibility()
                status = onCheckAgain()
            }

            Text("If macOS opens System Settings, turn on Breadcrumbs there, then come back and click Check Again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Later", action: onDismiss)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Check Again") {
                    status = onCheckAgain()
                    if status.isComplete {
                        onDismiss()
                    }
                }
                Button("Done") {
                    onDismiss()
                }
                .disabled(!status.isComplete)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isGranted ? Color.green : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Text(isGranted ? "Allowed" : "Needed")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isGranted ? Color.green : Color.secondary)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(buttonTitle, action: action)
                    .disabled(isGranted)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
