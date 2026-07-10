import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct FinderWindowSnapshot: Equatable {
    var frame: CGRect
    var state: FinderState?
}

enum FinderWindowTrackerUpdate: Equatable {
    case snapshot(FinderWindowSnapshot)
    case hidden
    case temporarilyHiddenForMotion
}

enum FinderMotionChangeSource {
    case accessibilityNotification
    case polledFrame
}

enum FinderMotionHidingPolicy {
    static func shouldHide(
        source: FinderMotionChangeSource,
        suppressionDeadline: Date?,
        now: Date
    ) -> Bool {
        switch source {
        case .accessibilityNotification:
            return true
        case .polledFrame:
            guard let suppressionDeadline else { return true }
            return suppressionDeadline <= now
        }
    }
}

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

final class FinderWindowTracker {
    var onUpdate: ((FinderWindowTrackerUpdate) -> Void)?
    var shouldRemainVisible: (() -> Bool)?

    private let config: AppConfig
    private let automationService: FinderAutomationServing
    private var timer: Timer?
    private var lastSnapshot: FinderWindowSnapshot?
    private var stateRefreshCache = FinderStateRefreshCache()
    private var pollReentrancyGate = FinderPollReentrancyGate()
    private var isUsingActiveInterval = false
    private var currentInterval: TimeInterval?
    private var motionTrackingDeadline: Date?
    private var finderObserver: AXObserver?
    private var finderObservedPID: pid_t?
    private var observedAppElement: AXUIElement?
    private var observedWindowElement: AXUIElement?
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
        rescheduleTimer(finderIsFrontmost: isFinderFrontmost())
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelBurstRefreshes()
        cancelMotionHiding()
        teardownAccessibilityObservation()
    }

    func refreshNow() {
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
                if shouldHideForPolledMotionChange(), beginMotionHiding(with: snapshot) {
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
            let refreshedState = automationService.currentState()
            stateRefreshCache.store(refreshedState, refreshedAt: now)
        }

        let state = stateRefreshCache.state

        if let state {
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
                _ = beginMotionHiding()
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

    private func beginMotionHiding(with snapshot: FinderWindowSnapshot? = nil) -> Bool {
        guard shouldRemainVisible?() != true else {
            cancelMotionHiding()
            return false
        }

        if let snapshot {
            pendingMotionSnapshot = snapshot
        }

        if !isTemporarilyHiddenForMotion {
            isTemporarilyHiddenForMotion = true
            emitTemporarilyHiddenForMotion()
        }

        scheduleMotionSettleRefresh()
        return true
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

    private func shouldHideForPolledMotionChange() -> Bool {
        let now = Date()
        let shouldHide = FinderMotionHidingPolicy.shouldHide(
            source: .polledFrame,
            suppressionDeadline: suppressMotionHidingUntil,
            now: now
        )
        if shouldHide {
            suppressMotionHidingUntil = nil
        }
        return shouldHide
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
        let state = automationService.currentState()
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
