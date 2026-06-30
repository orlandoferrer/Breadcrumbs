import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let panel: FocusablePanel
    private let viewModel: PathBarViewModel
    private let panelLevel = NSWindow.Level.statusBar
    private var visibilityHoldUntil: Date?
    private var outsideClickMonitor: Any?

    init(viewModel: PathBarViewModel) {
        self.viewModel = viewModel

        let panel = FocusablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 34),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = panelLevel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.appearance = Self.pinnedAppearance()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.onResignKey = { [weak viewModel] in
            guard viewModel?.isEditing == true else { return }
            viewModel?.cancelEditing(returnFocusToFinder: false)
        }

        self.panel = panel
        panel.onMouseDown = { [weak self] in
            guard let self, !self.viewModel.isEditing else { return }
            self.beginEditing()
        }
        panel.contentView = NSHostingView(rootView: makeRootView())
    }

    func update(with snapshot: FinderWindowSnapshot, config: AppConfig) {
        let frame = frame(for: snapshot.frame, config: config)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        visibilityHoldUntil = nil
        removeOutsideClickMonitor()
        panel.orderOut(nil)
    }

    func cancelEditingAndHide(returnFocusToFinder: Bool = false) {
        if viewModel.isEditing {
            viewModel.cancelEditing(returnFocusToFinder: returnFocusToFinder)
        }
        hide()
    }

    var shouldHoldVisibility: Bool {
        guard panel.isVisible else { return false }
        if panel.isKeyWindow {
            return viewModel.isEditing
        }
        guard let visibilityHoldUntil else { return false }
        return viewModel.isEditing && visibilityHoldUntil > Date()
    }

    @discardableResult
    func beginEditing() -> Bool {
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        visibilityHoldUntil = Date().addingTimeInterval(0.6)
        guard viewModel.beginEditing() else {
            visibilityHoldUntil = nil
            return false
        }
        installOutsideClickMonitor()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func endEditing() {
        visibilityHoldUntil = nil
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak panel, weak viewModel] _ in
            Task { @MainActor in
                if let panel, panel.frame.contains(NSEvent.mouseLocation) {
                    return
                }
                guard viewModel?.isEditing == true else { return }
                viewModel?.cancelEditing(returnFocusToFinder: false)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func frame(for finderFrame: CGRect, config: AppConfig) -> NSRect {
        let convertedFinderFrame = convertWindowServerRectToAppKit(finderFrame)
        let proportionalInset = convertedFinderFrame.width * 0.02
        let sideInset = config.horizontalInset + proportionalInset
        let width = max(320, convertedFinderFrame.width - (sideInset * 2))
        let x = convertedFinderFrame.origin.x + sideInset
        let y = convertedFinderFrame.origin.y - config.preferredBarHeight - config.verticalGap
        return NSRect(x: x, y: y, width: width, height: config.preferredBarHeight)
    }

    private func convertWindowServerRectToAppKit(_ rect: CGRect) -> CGRect {
        guard let screen = screenForWindowServerRect(rect) ?? NSScreen.main else {
            return rect
        }

        let screenFrame = screen.frame
        let convertedY = screenFrame.maxY - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: convertedY, width: rect.width, height: rect.height)
    }

    private func screenForWindowServerRect(_ rect: CGRect) -> NSScreen? {
        let midpointX = rect.midX
        return NSScreen.screens.first { screen in
            midpointX >= screen.frame.minX && midpointX <= screen.frame.maxX
        }
    }

    private func makeRootView() -> PathBarView {
        PathBarView(
            viewModel: viewModel,
            onActivateEditing: { [weak self] in
                self?.beginEditing()
            }
        )
    }

    private static func pinnedAppearance() -> NSAppearance? {
        let baseAppearance = NSApp.effectiveAppearance
        let name = baseAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
        return NSAppearance(named: name)
    }
}

private final class FocusablePanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onMouseDown: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onMouseDown?()
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
