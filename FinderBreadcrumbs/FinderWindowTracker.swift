import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct FinderWindowSnapshot: Equatable {
    var frame: CGRect
    var state: FinderState?
}

final class FinderWindowTracker {
    var onUpdate: ((FinderWindowSnapshot?) -> Void)?
    var shouldRemainVisible: (() -> Bool)?

    private let config: AppConfig
    private let automationService: FinderAutomationServing
    private var timer: Timer?
    private var lastSnapshot: FinderWindowSnapshot?
    private var isUsingActiveInterval = false
    private var currentInterval: TimeInterval?
    private var motionTrackingDeadline: Date?
    private var finderObserver: AXObserver?
    private var finderObservedPID: pid_t?
    private var observedAppElement: AXUIElement?
    private var observedWindowElement: AXUIElement?
    private var pendingBurstRefreshes: [DispatchWorkItem] = []

    init(config: AppConfig, automationService: FinderAutomationServing) {
        self.config = config
        self.automationService = automationService
    }

    func start() {
        syncAccessibilityObservation()
        rescheduleTimer(finderIsFrontmost: isFinderFrontmost())
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelBurstRefreshes()
        teardownAccessibilityObservation()
    }

    func refreshNow() {
        poll()
    }

    @objc
    private func poll() {
        syncAccessibilityObservation()
        let finderIsFrontmost = isFinderFrontmost()
        if finderIsFrontmost != isUsingActiveInterval {
            rescheduleTimer(finderIsFrontmost: finderIsFrontmost)
        }

        guard finderIsFrontmost else {
            motionTrackingDeadline = nil
            if shouldRemainVisible?() == true {
                return
            }
            if lastSnapshot != nil {
                lastSnapshot = nil
                onUpdate?(nil)
            }
            return
        }

        guard let snapshot = captureSnapshot() else {
            // Finder can briefly stop reporting a target while changing tabs.
            // Keep the current overlay visible until we get the next stable snapshot.
            return
        }

        if snapshot != lastSnapshot {
            if let lastSnapshot, snapshot.frame != lastSnapshot.frame {
                motionTrackingDeadline = Date().addingTimeInterval(config.motionTrackingDuration)
            }
            lastSnapshot = snapshot
            onUpdate?(snapshot)
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

    private func captureSnapshot() -> FinderWindowSnapshot? {
        guard let finderPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?
            .processIdentifier else {
            return nil
        }

        guard let frame = frontmostWindowFrame(for: finderPID) else {
            return nil
        }

        return FinderWindowSnapshot(frame: frame, state: automationService.currentState())
    }

    private func frontmostWindowFrame(for processID: pid_t) -> CGRect? {
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

            return frame
        }

        return nil
    }

    private func isFinderFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    private func syncAccessibilityObservation() {
        guard AccessibilityPermissionManager.isTrusted else {
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
            refreshNow()
            scheduleBurstRefreshes()
        case kAXMovedNotification,
             kAXResizedNotification:
            motionTrackingDeadline = Date().addingTimeInterval(config.motionTrackingDuration)
            refreshNow()
            scheduleBurstRefreshes()
        default:
            break
        }
    }

    private func scheduleBurstRefreshes() {
        cancelBurstRefreshes()

        let delays: [TimeInterval] = [0.016, 0.032, 0.05, 0.075]
        pendingBurstRefreshes = delays.map { delay in
            let workItem = DispatchWorkItem { [weak self] in
                self?.refreshNow()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }

    private func cancelBurstRefreshes() {
        pendingBurstRefreshes.forEach { $0.cancel() }
        pendingBurstRefreshes.removeAll()
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
