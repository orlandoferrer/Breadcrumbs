import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The two pieces of data needed to render the bar: Finder's screen rectangle
/// and the directory represented by that Finder window.
struct FinderWindowSnapshot: Equatable {
    var frame: CGRect
    var state: FinderState?
}

/// Events emitted by `FinderWindowTracker` to `AppCoordinator`.
enum FinderWindowTrackerUpdate: Equatable {
    case snapshot(FinderWindowSnapshot)
    case hidden
    case hiddenForQuickLook
    case temporarilyHiddenForMotion
}

/// Describes how the tracker learned that Finder's frame changed. Polled moves
/// may be stale after settling, while resize and AX events are authoritative.
enum FinderMotionChangeSource {
    case accessibilityNotification
    case polledMove
    case polledResize
}

/// Pure decision logic for whether a frame change should hide the overlay.
/// Keeping it free of AppKit state makes the edge cases easy to test.
enum FinderMotionHidingPolicy {
    static func shouldHide(
        source: FinderMotionChangeSource,
        suppressionDeadline: Date?,
        now: Date
    ) -> Bool {
        switch source {
        case .accessibilityNotification, .polledResize:
            return true
        case .polledMove:
            guard let suppressionDeadline else { return true }
            return suppressionDeadline <= now
        }
    }
}

enum FinderMotionCompletionPolicy {
    static func shouldFinish(isResizeDragInProgress: Bool) -> Bool {
        !isResizeDragInProgress
    }
}

/// Approximates Finder's draggable resize border, including larger hit regions
/// around rounded corners where the visible edge is not rectangular.
enum FinderResizeHitTester {
    static func isResizeBorderHit(
        point: CGPoint,
        frame: CGRect,
        edgeTolerance: CGFloat = 8,
        cornerTolerance: CGFloat = 20
    ) -> Bool {
        let expandedFrame = frame.insetBy(dx: -cornerTolerance, dy: -cornerTolerance)
        guard expandedFrame.contains(point) else { return false }

        let distanceToHorizontalEdge = min(
            abs(point.x - frame.minX),
            abs(point.x - frame.maxX)
        )
        let distanceToVerticalEdge = min(
            abs(point.y - frame.minY),
            abs(point.y - frame.maxY)
        )
        let isRoundedCornerHit = distanceToHorizontalEdge <= cornerTolerance
            && distanceToVerticalEdge <= cornerTolerance

        return isRoundedCornerHit
            || distanceToHorizontalEdge <= edgeTolerance
            || distanceToVerticalEdge <= edgeTolerance
    }
}

/// Classifies Finder's Accessibility windows without depending on their title.
enum QuickLookAXWindowDetector {
    static func isPreviewWindow(role: String?, subrole: String?, title: String?) -> Bool {
        // "Quick Look" is Finder's dedicated AX subrole. The visible title is
        // deliberately ignored because it can be localized or changed by macOS.
        role == kAXWindowRole as String
            && subrole == "Quick Look"
    }
}

/// Throttles expensive Apple Event reads while allowing window frames to be
/// sampled at the faster motion interval.
struct FinderStateRefreshCache {
    private var cachedState: FinderState?
    private var lastRefreshDate: Date?

    var state: FinderState? {
        cachedState
    }

    func shouldRefresh(
        now: Date,
        minimumInterval: TimeInterval,
        forceRefresh: Bool
    ) -> Bool {
        let cacheExpired = lastRefreshDate.map {
            now.timeIntervalSince($0) >= minimumInterval
        } ?? true
        return forceRefresh || cacheExpired
    }

    mutating func store(_ state: FinderState?, refreshedAt date: Date) {
        cachedState = state
        lastRefreshDate = date
    }
}

/// Converts nested poll requests into at most one follow-up poll.
///
/// Polling can synchronously trigger callbacks through macOS frameworks. Running
/// a second poll while the first mutates state previously caused Swift exclusive
/// access failures, so requests are coalesced instead.
struct FinderPollReentrancyGate {
    private var isActive = false
    private var hasPendingPoll = false
    private var pendingForceRefresh = false

    mutating func begin(forceRefresh: Bool) -> Bool {
        guard !isActive else {
            hasPendingPoll = true
            pendingForceRefresh = pendingForceRefresh || forceRefresh
            return false
        }

        isActive = true
        return true
    }

    mutating func finish() -> (shouldPoll: Bool, forceRefresh: Bool) {
        isActive = false
        let pending = (hasPendingPoll, pendingForceRefresh)
        hasPendingPoll = false
        pendingForceRefresh = false
        return pending
    }
}

/// Discovers the frontmost Finder window and emits snapshots for the overlay.
///
/// Finder does not expose one API containing both window geometry and folder
/// state, so this class combines three mechanisms:
/// - Core Graphics finds the frontmost Finder window and its frame.
/// - Apple Events load the active tab's directory and Finder window ID.
/// - Accessibility notifications improve move/resize tracking and detect Quick Look.
///
/// Mutable tracker state is confined to the main thread. The class is marked
/// `@unchecked Sendable` only because the AppleScript request captures a weak
/// reference before dispatching its result back to the main queue.
final class FinderWindowTracker: @unchecked Sendable {
    var onUpdate: ((FinderWindowTrackerUpdate) -> Void)?
    var shouldRemainVisible: (() -> Bool)?

    private let config: AppConfig
    private let automationService: FinderAutomationServing
    private let stateRefreshQueue = DispatchQueue(
        label: "com.orlando.FinderBreadcrumbs.finder-state-refresh",
        qos: .utility
    )
    private var timer: Timer?
    private var isRunning = false
    private var lastSnapshot: FinderWindowSnapshot?
    private var stateRefreshCache = FinderStateRefreshCache()
    private var isStateRefreshInFlight = false
    private var hasPendingForcedStateRefresh = false
    private var pollReentrancyGate = FinderPollReentrancyGate()
    private var isUsingActiveInterval = false
    private var currentInterval: TimeInterval?
    private var motionTrackingDeadline: Date?
    private var finderObserver: AXObserver?
    private var finderObservedPID: pid_t?
    private var observedAppElement: AXUIElement?
    private var observedWindowElement: AXUIElement?
    private var globalMouseMonitor: Any?
    private var isResizeDragInProgress = false
    private var pendingBurstRefreshes: [DispatchWorkItem] = []
    private var motionSettleRefresh: DispatchWorkItem?
    private var pendingMotionSnapshot: FinderWindowSnapshot?
    private var isTemporarilyHiddenForMotion = false
    private var isOverlayHidden = true
    private var didPromptForAccessibilityThisRun = false
    private var suppressMotionHidingUntil: Date?
    private var lastDiagnosticSignature: String?
    private var missingSnapshotGraceUntil: Date?
    private var lastCaptureWasKnownChildWindow = false
    private let missingSnapshotGraceDuration: TimeInterval = 0.25
    private let motionSettleDelay: TimeInterval = 0.15
    private let motionHidingSuppressionDuration: TimeInterval = 0.35

    init(config: AppConfig, automationService: FinderAutomationServing) {
        self.config = config
        self.automationService = automationService
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installGlobalMouseMonitor()
        rescheduleTimer(finderIsFrontmost: isFinderFrontmost())
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        cancelBurstRefreshes()
        cancelMotionHiding()
        removeGlobalMouseMonitor()
        teardownAccessibilityObservation()
    }

    func refreshNow() {
        guard isRunning else { return }
        performPoll(forceFinderStateRefresh: true)
    }

    @objc
    private func poll() {
        performPoll(forceFinderStateRefresh: false)
    }

    private func refreshFrameNow() {
        performPoll(forceFinderStateRefresh: false)
    }

    private func performPoll(forceFinderStateRefresh: Bool) {
        guard isRunning else { return }
        var forceRefresh = forceFinderStateRefresh

        while pollReentrancyGate.begin(forceRefresh: forceRefresh) {
            performSinglePoll(forceFinderStateRefresh: forceRefresh)
            let pendingPoll = pollReentrancyGate.finish()
            guard pendingPoll.shouldPoll else {
                return
            }

            forceRefresh = pendingPoll.forceRefresh
        }
    }

    private func performSinglePoll(forceFinderStateRefresh: Bool) {
        let finderIsFrontmost = isFinderFrontmost()
        if finderIsFrontmost {
            syncAccessibilityObservation()
        } else {
            teardownAccessibilityObservation()
        }

        if finderIsFrontmost != isUsingActiveInterval {
            rescheduleTimer(finderIsFrontmost: finderIsFrontmost)
        }

        guard finderIsFrontmost else {
            motionTrackingDeadline = nil
            suppressMotionHidingUntil = nil
            lastDiagnosticSignature = nil
            missingSnapshotGraceUntil = nil
            lastCaptureWasKnownChildWindow = false
            cancelMotionHiding()
            if shouldRemainVisible?() == true {
                return
            }
            emitHidden(preserveLastSnapshot: true)
            return
        }

        guard !isQuickLookPreviewVisible() else {
            cancelMotionHiding()
            emitQuickLookHidden()
            return
        }

        logFinderWindowDiagnostics(reason: "poll")

        guard let snapshot = captureSnapshot(forceFinderStateRefresh: forceFinderStateRefresh) else {
            if shouldRemainVisible?() == true {
                missingSnapshotGraceUntil = nil
                return
            }
            if isTemporarilyHiddenForMotion, !lastCaptureWasKnownChildWindow {
                pendingMotionSnapshot = pendingMotionSnapshot ?? lastSnapshot
                scheduleMotionSettleRefreshIfNeeded()
                return
            }
            if shouldKeepLastSnapshotDuringTransientMiss() {
                return
            }
            cancelMotionHiding()
            emitHidden(preserveLastSnapshot: lastCaptureWasKnownChildWindow)
            missingSnapshotGraceUntil = nil
            return
        }

        missingSnapshotGraceUntil = nil
        lastCaptureWasKnownChildWindow = false
        if snapshot != lastSnapshot {
            if let lastSnapshot, snapshot.frame != lastSnapshot.frame {
                motionTrackingDeadline = Date().addingTimeInterval(config.motionTrackingDuration)
                let changeSource: FinderMotionChangeSource =
                    snapshot.frame.size == lastSnapshot.frame.size ? .polledMove : .polledResize
                if shouldHideForPolledMotionChange(source: changeSource) {
                    beginMotionHiding(with: snapshot)
                    self.lastSnapshot = snapshot
                    updateTimerIfNeeded(finderIsFrontmost: finderIsFrontmost)
                    return
                }
            }
            lastSnapshot = snapshot
            if isTemporarilyHiddenForMotion {
                pendingMotionSnapshot = snapshot
            } else {
                emitSnapshot(snapshot)
            }
        } else if isTemporarilyHiddenForMotion {
            pendingMotionSnapshot = snapshot
        } else if isOverlayHidden {
            emitSnapshot(snapshot)
        }

        updateTimerIfNeeded(finderIsFrontmost: finderIsFrontmost)
    }

    private func rescheduleTimer(finderIsFrontmost: Bool) {
        timer?.invalidate()
        isUsingActiveInterval = finderIsFrontmost
        let interval = pollInterval(finderIsFrontmost: finderIsFrontmost)
        currentInterval = interval
        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        if let timer {
            timer.tolerance = tolerance(for: interval, finderIsFrontmost: finderIsFrontmost)
            RunLoop.main.add(timer, forMode: .common)
        }
        poll()
    }

    private func updateTimerIfNeeded(finderIsFrontmost: Bool) {
        let interval = pollInterval(finderIsFrontmost: finderIsFrontmost)
        guard currentInterval != interval else { return }
        rescheduleTimer(finderIsFrontmost: finderIsFrontmost)
    }

    private func pollInterval(finderIsFrontmost: Bool) -> TimeInterval {
        guard finderIsFrontmost else {
            return config.inactivePollInterval
        }

        if let motionTrackingDeadline, motionTrackingDeadline > Date() {
            return config.motionPollInterval
        }

        return config.activePollInterval
    }

    private func tolerance(for interval: TimeInterval, finderIsFrontmost: Bool) -> TimeInterval {
        guard finderIsFrontmost else {
            return min(0.2, interval * 0.25)
        }

        if interval <= config.motionPollInterval {
            return min(0.008, interval * 0.2)
        }

        return min(0.02, interval * 0.25)
    }

    private func shouldKeepLastSnapshotDuringTransientMiss() -> Bool {
        guard lastSnapshot != nil, !lastCaptureWasKnownChildWindow else {
            missingSnapshotGraceUntil = nil
            return false
        }

        let now = Date()
        if let missingSnapshotGraceUntil {
            return missingSnapshotGraceUntil > now
        }

        missingSnapshotGraceUntil = now.addingTimeInterval(missingSnapshotGraceDuration)
        return true
    }

    private func emitSnapshot(_ snapshot: FinderWindowSnapshot) {
        isOverlayHidden = false
        onUpdate?(.snapshot(snapshot))
    }

    private func emitHidden(preserveLastSnapshot: Bool = false) {
        if !preserveLastSnapshot {
            lastSnapshot = nil
        }

        guard !isOverlayHidden else { return }
        isOverlayHidden = true
        onUpdate?(.hidden)
    }

    private func emitTemporarilyHiddenForMotion() {
        guard !isOverlayHidden else { return }
        isOverlayHidden = true
        onUpdate?(.temporarilyHiddenForMotion)
    }

    private func emitQuickLookHidden() {
        isOverlayHidden = true
        onUpdate?(.hiddenForQuickLook)
    }

    private func captureSnapshot(forceFinderStateRefresh: Bool) -> FinderWindowSnapshot? {
        lastCaptureWasKnownChildWindow = false
        guard let finderPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?
            .processIdentifier else {
            return nil
        }

        guard let windowInfo = frontmostWindowInfo(for: finderPID) else {
            return nil
        }

        let now = Date()
        if stateRefreshCache.shouldRefresh(
            now: now,
            minimumInterval: config.activePollInterval,
            forceRefresh: forceFinderStateRefresh
        ) {
            requestStateRefresh(forceRefresh: forceFinderStateRefresh)
        }

        let state = stateRefreshCache.state

        if let state {
            // Never pair a path from one Finder window with another window's
            // frame. Temporary child windows can appear ahead of the browser
            // window in the Core Graphics list.
            guard windowInfo.number == nil || windowInfo.number == state.windowID else {
                lastCaptureWasKnownChildWindow = true
                return nil
            }

            return FinderWindowSnapshot(frame: windowInfo.frame, state: state)
        }

        if let lastSnapshot,
           let windowNumber = windowInfo.number,
           windowNumber == lastSnapshot.state?.windowID {
            return FinderWindowSnapshot(frame: windowInfo.frame, state: lastSnapshot.state)
        }

        if windowInfo.number != nil {
            lastCaptureWasKnownChildWindow = true
        }
        return nil
    }

    private func requestStateRefresh(forceRefresh: Bool) {
        guard isRunning else { return }
        guard !isStateRefreshInFlight else {
            hasPendingForcedStateRefresh = hasPendingForcedStateRefresh || forceRefresh
            return
        }

        isStateRefreshInFlight = true
        let automationService = automationService
        // Only AppleScript execution happens off-main. All cache and lifecycle
        // state returns to the main queue before mutation.
        stateRefreshQueue.async { [weak self] in
            let state = automationService.currentState()
            DispatchQueue.main.async { [weak self] in
                self?.completeStateRefresh(state)
            }
        }
    }

    private func completeStateRefresh(_ state: FinderState?) {
        isStateRefreshInFlight = false
        guard isRunning else {
            hasPendingForcedStateRefresh = false
            return
        }
        stateRefreshCache.store(state, refreshedAt: Date())

        if hasPendingForcedStateRefresh {
            hasPendingForcedStateRefresh = false
            requestStateRefresh(forceRefresh: true)
            return
        }

        performPoll(forceFinderStateRefresh: false)
    }

    private func frontmostWindowInfo(for processID: pid_t) -> FinderCGWindowInfo? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowInfoList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == processID,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = windowInfo[kCGWindowAlpha as String] as? Double,
                  alpha > 0,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  frame.width > 200,
                  frame.height > 100 else {
                continue
            }

            let title = windowInfo[kCGWindowName as String] as? String
            let number = windowInfo[kCGWindowNumber as String] as? Int
            return FinderCGWindowInfo(number: number, title: title, layer: layer, alpha: alpha, frame: frame)
        }

        return nil
    }

    private func isFinderFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    private func installGlobalMouseMonitor() {
        guard globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            self?.handleGlobalInputEvent(event)
        }
    }

    private func removeGlobalMouseMonitor() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        isResizeDragInProgress = false
    }

    private func handleGlobalInputEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard isFinderFrontmost(), let lastSnapshot else { return }
            let mousePoint = windowServerPoint(fromAppKitPoint: NSEvent.mouseLocation)
            guard FinderResizeHitTester.isResizeBorderHit(
                point: mousePoint,
                frame: lastSnapshot.frame
            ) else { return }

            isResizeDragInProgress = true
            beginMotionHiding(with: lastSnapshot)
        case .leftMouseUp:
            guard isResizeDragInProgress else { return }
            isResizeDragInProgress = false
            scheduleMotionSettleRefresh()
        default:
            break
        }
    }

    private func windowServerPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
    }

    private func syncAccessibilityObservation() {
        guard AccessibilityPermissionManager.isTrusted else {
            if !didPromptForAccessibilityThisRun {
                didPromptForAccessibilityThisRun = true
                AccessibilityPermissionManager.ensurePrompted()
            }
            teardownAccessibilityObservation()
            return
        }

        guard let finderPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?
            .processIdentifier else {
            teardownAccessibilityObservation()
            return
        }

        guard finderObservedPID != finderPID || finderObserver == nil else {
            return
        }

        teardownAccessibilityObservation()

        var observerRef: AXObserver?
        let result = AXObserverCreate(finderPID, finderAXObserverCallback, &observerRef)
        guard result == .success, let observerRef else {
            return
        }

        finderObserver = observerRef
        finderObservedPID = finderPID
        observedAppElement = AXUIElementCreateApplication(finderPID)

        // AXObserver callbacks are delivered through a CFRunLoop source. Adding
        // it to the main run loop keeps tracker mutations serialized with Timer.
        let source = AXObserverGetRunLoopSource(observerRef)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        if let observedAppElement {
            addNotification(kAXFocusedWindowChangedNotification as CFString, for: observedAppElement)
            addNotification(kAXMainWindowChangedNotification as CFString, for: observedAppElement)
        }

        attachToFocusedWindow()
    }

    private func teardownAccessibilityObservation() {
        if let observer = finderObserver, let observedWindowElement {
            removeNotification(kAXMovedNotification as CFString, for: observedWindowElement, observer: observer)
            removeNotification(kAXResizedNotification as CFString, for: observedWindowElement, observer: observer)
        }

        if let observer = finderObserver, let observedAppElement {
            removeNotification(kAXFocusedWindowChangedNotification as CFString, for: observedAppElement, observer: observer)
            removeNotification(kAXMainWindowChangedNotification as CFString, for: observedAppElement, observer: observer)
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        observedWindowElement = nil
        observedAppElement = nil
        finderObserver = nil
        finderObservedPID = nil
    }

    private func addNotification(_ notification: CFString, for element: AXUIElement) {
        guard let finderObserver else { return }
        let result = AXObserverAddNotification(
            finderObserver,
            element,
            notification,
            Unmanaged.passUnretained(self).toOpaque()
        )

        guard result == .success || result == .notificationAlreadyRegistered else {
            return
        }
    }

    private func removeNotification(_ notification: CFString, for element: AXUIElement, observer: AXObserver) {
        AXObserverRemoveNotification(observer, element, notification)
    }

    private func attachToFocusedWindow() {
        guard let observedAppElement else { return }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            observedAppElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )

        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            detachObservedWindow()
            return
        }

        let nextWindowElement = unsafeDowncast(value as AnyObject, to: AXUIElement.self)
        if let observedWindowElement, CFEqual(observedWindowElement, nextWindowElement) {
            return
        }

        detachObservedWindow()
        observedWindowElement = nextWindowElement
        addNotification(kAXMovedNotification as CFString, for: nextWindowElement)
        addNotification(kAXResizedNotification as CFString, for: nextWindowElement)
    }

    private func detachObservedWindow() {
        guard let finderObserver, let observedWindowElement else { return }
        removeNotification(kAXMovedNotification as CFString, for: observedWindowElement, observer: finderObserver)
        removeNotification(kAXResizedNotification as CFString, for: observedWindowElement, observer: finderObserver)
        self.observedWindowElement = nil
    }

    fileprivate func handleAccessibilityNotification(_ notification: String) {
        switch notification {
        case kAXFocusedWindowChangedNotification,
             kAXMainWindowChangedNotification:
            attachToFocusedWindow()
            logFinderWindowDiagnostics(reason: notification)
            refreshNow()
            scheduleFrameBurstRefreshes()
        case kAXMovedNotification,
             kAXResizedNotification:
            motionTrackingDeadline = Date().addingTimeInterval(config.motionTrackingDuration)
            if FinderMotionHidingPolicy.shouldHide(
                source: .accessibilityNotification,
                suppressionDeadline: suppressMotionHidingUntil,
                now: Date()
            ) {
                beginMotionHiding()
            }
            logFinderWindowDiagnostics(reason: notification)
            refreshFrameNow()
            scheduleFrameBurstRefreshes()
        default:
            break
        }
    }

    private func scheduleFrameBurstRefreshes() {
        cancelBurstRefreshes()

        let delays: [TimeInterval] = [0.016, 0.032, 0.05, 0.075]
        pendingBurstRefreshes = delays.map { delay in
            let workItem = DispatchWorkItem { [weak self] in
                self?.refreshFrameNow()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }

    private func cancelBurstRefreshes() {
        pendingBurstRefreshes.forEach { $0.cancel() }
        pendingBurstRefreshes.removeAll()
    }

    private func beginMotionHiding(with snapshot: FinderWindowSnapshot? = nil) {
        if let snapshot {
            pendingMotionSnapshot = snapshot
        }

        if !isTemporarilyHiddenForMotion {
            isTemporarilyHiddenForMotion = true
            emitTemporarilyHiddenForMotion()
        }

        // Every new motion signal pushes the settle deadline out. Resize drags
        // additionally remain hidden until the global mouse-up event arrives.
        scheduleMotionSettleRefresh()
    }

    private func scheduleMotionSettleRefresh() {
        motionSettleRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishMotionHiding()
        }
        motionSettleRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + motionSettleDelay, execute: workItem)
    }

    private func scheduleMotionSettleRefreshIfNeeded() {
        guard motionSettleRefresh == nil else { return }
        scheduleMotionSettleRefresh()
    }

    private func finishMotionHiding() {
        motionSettleRefresh = nil
        guard isTemporarilyHiddenForMotion else { return }
        guard FinderMotionCompletionPolicy.shouldFinish(
            isResizeDragInProgress: isResizeDragInProgress
        ) else {
            scheduleMotionSettleRefresh()
            return
        }
        isTemporarilyHiddenForMotion = false
        motionTrackingDeadline = nil
        suppressMotionHidingUntil = Date().addingTimeInterval(motionHidingSuppressionDuration)

        if let pendingMotionSnapshot {
            self.pendingMotionSnapshot = nil
            emitSnapshot(pendingMotionSnapshot)
        } else {
            refreshFrameNow()
        }

        updateTimerIfNeeded(finderIsFrontmost: isFinderFrontmost())
    }

    private func cancelMotionHiding() {
        motionSettleRefresh?.cancel()
        motionSettleRefresh = nil
        pendingMotionSnapshot = nil
        isTemporarilyHiddenForMotion = false
        suppressMotionHidingUntil = nil
    }

    private func shouldHideForPolledMotionChange(source: FinderMotionChangeSource) -> Bool {
        let now = Date()
        let shouldHide = FinderMotionHidingPolicy.shouldHide(
            source: source,
            suppressionDeadline: suppressMotionHidingUntil,
            now: now
        )
        if shouldHide {
            suppressMotionHidingUntil = nil
        }
        return shouldHide
    }

    private func isQuickLookPreviewVisible() -> Bool {
        guard AccessibilityPermissionManager.isTrusted, let observedAppElement else { return false }

        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            observedAppElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard result == .success else { return false }
        let windows = windowsValue as? [AXUIElement] ?? []
        return windows.contains { window in
            QuickLookAXWindowDetector.isPreviewWindow(
                role: stringAttribute(kAXRoleAttribute, from: window),
                subrole: stringAttribute(kAXSubroleAttribute, from: window),
                title: stringAttribute(kAXTitleAttribute, from: window)
            )
        }
    }

    private func logFinderWindowDiagnostics(reason: String) {
        guard config.debugLogFinderWindowDiagnostics else { return }
        guard let finderPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?
            .processIdentifier else {
            return
        }

        let cgInfo = frontmostWindowInfo(for: finderPID)
        let axInfo = focusedWindowDiagnostics(for: finderPID)
        let state = stateRefreshCache.state
        let signature = [
            cgInfo?.signature ?? "cg:nil",
            axInfo?.signature ?? "ax:nil",
            state.map { "state:\($0.windowID):\($0.resolvedPath)" } ?? "state:nil"
        ].joined(separator: "|")

        guard signature != lastDiagnosticSignature else { return }
        lastDiagnosticSignature = signature

        NSLog(
            """
            FinderBreadcrumbs Finder window diagnostics [%@]
              CG: %@
              AX: %@
              FinderState: %@
            """,
            reason,
            cgInfo?.logDescription ?? "nil",
            axInfo?.logDescription ?? "nil",
            state.map { "windowID=\($0.windowID) displayedPath=\($0.displayedPath) resolvedPath=\($0.resolvedPath)" } ?? "nil"
        )
    }

    private func focusedWindowDiagnostics(for finderPID: pid_t) -> FinderAXWindowInfo? {
        let appElement = observedAppElement ?? AXUIElementCreateApplication(finderPID)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )

        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return FinderAXWindowInfo(
                role: nil,
                subrole: nil,
                title: nil,
                document: nil,
                frame: nil,
                copyResult: result
            )
        }

        let windowElement = unsafeDowncast(value as AnyObject, to: AXUIElement.self)
        return FinderAXWindowInfo(
            role: stringAttribute(kAXRoleAttribute, from: windowElement),
            subrole: stringAttribute(kAXSubroleAttribute, from: windowElement),
            title: stringAttribute(kAXTitleAttribute, from: windowElement),
            document: stringAttribute(kAXDocumentAttribute, from: windowElement),
            frame: axFrame(for: windowElement),
            copyResult: result
        )
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        return String(describing: value)
    }

    private func axFrame(for element: AXUIElement) -> CGRect? {
        guard let position = cgPointAttribute(kAXPositionAttribute, from: element),
              let size = cgSizeAttribute(kAXSizeAttribute, from: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func cgPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func cgSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return nil
        }
        return size
    }
}

private struct FinderCGWindowInfo {
    var number: Int?
    var title: String?
    var layer: Int
    var alpha: Double
    var frame: CGRect

    var signature: String {
        "cg:\(number ?? -1):\(title ?? ""):\(frame.debugDescription)"
    }

    var logDescription: String {
        "number=\(number.map(String.init) ?? "nil") title=\(title ?? "nil") layer=\(layer) alpha=\(alpha) frame=\(frame.debugDescription)"
    }
}

private struct FinderAXWindowInfo {
    var role: String?
    var subrole: String?
    var title: String?
    var document: String?
    var frame: CGRect?
    var copyResult: AXError

    var signature: String {
        "ax:\(role ?? ""):\(subrole ?? ""):\(title ?? ""):\(document ?? ""):\(frame?.debugDescription ?? ""):\(copyResult.rawValue)"
    }

    var logDescription: String {
        "result=\(copyResult.rawValue) role=\(role ?? "nil") subrole=\(subrole ?? "nil") title=\(title ?? "nil") document=\(document ?? "nil") frame=\(frame?.debugDescription ?? "nil")"
    }
}

private func finderAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<FinderWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handleAccessibilityNotification(notification as String)
}
