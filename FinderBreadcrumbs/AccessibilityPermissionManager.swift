import ApplicationServices

enum AccessibilityPermissionManager {
    static func ensurePrompted() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }
}
