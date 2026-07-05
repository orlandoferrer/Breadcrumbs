import ApplicationServices
import Foundation

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

    private static func trustOptions(prompt: Bool) -> CFDictionary {
        ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
    }
}
