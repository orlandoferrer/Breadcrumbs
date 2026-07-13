import ApplicationServices
import Foundation

/// A shared UI representation for macOS privacy permission results.
enum PermissionState {
    case granted
    case denied
    case notDetermined
    case unknown
}

/// Wraps the process-wide Accessibility trust check.
///
/// Accessibility is optional for basic operation but enables better motion
/// tracking and Finder Quick Look detection.
enum AccessibilityPermissionManager {
    static func ensurePrompted() {
        guard !isTrusted else { return }
        let options = trustOptions(prompt: true)
        AXIsProcessTrustedWithOptions(options)
    }

    static var isTrusted: Bool {
        let options = trustOptions(prompt: false)
        return AXIsProcessTrustedWithOptions(options)
    }

    static var state: PermissionState {
        // The AX API cannot distinguish "denied" from "never asked".
        isTrusted ? .granted : .denied
    }

    private static func trustOptions(prompt: Bool) -> CFDictionary {
        ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
    }
}

/// Queries macOS's Transparency, Consent, and Control (TCC) state for Apple
/// Events sent from this app to Finder.
enum AutomationPermissionManager {
    /// Checks whether macOS allows this app to send Apple Events to Finder.
    /// With `promptIfNeeded` the call blocks until the user answers the
    /// consent dialog, so only pass true from a background queue.
    static func finderAutomationState(promptIfNeeded: Bool = false) -> PermissionState {
        var addressDesc = AEAddressDesc()
        let bundleID = "com.apple.finder"
        let creationStatus = bundleID.utf8CString.withUnsafeBufferPointer { buffer in
            AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count - 1, &addressDesc)
        }
        guard creationStatus == noErr else { return .unknown }
        defer { AEDisposeDesc(&addressDesc) }

        let status = AEDeterminePermissionToAutomateTarget(
            &addressDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            promptIfNeeded
        )

        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        default:
            // Includes procNotFound when Finder is not running.
            return .unknown
        }
    }
}
