import AppKit
import SwiftUI

@MainActor
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

private struct WelcomeView: View {
    let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Breadcrumbs")
                    .font(.title2.weight(.semibold))
                Text("Breadcrumbs follows Finder windows and lets you jump to folders from a small path bar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PermissionNote(
                symbolName: "folder",
                title: "Finder access",
                detail: "macOS may ask before Breadcrumbs can read folders from Finder or open folders on your behalf."
            )

            PermissionNote(
                symbolName: "accessibility",
                title: "Accessibility",
                detail: "macOS may ask before Breadcrumbs can track the active Finder window and place the path bar."
            )

            HStack {
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
    }
}

private struct PermissionNote: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
