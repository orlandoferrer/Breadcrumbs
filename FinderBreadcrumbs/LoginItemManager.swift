import Foundation
import ServiceManagement

protocol LoginItemServing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemServing {}

/// Small wrapper around Apple's modern launch-at-login service.
enum LoginItemManager {
    static var isEnabled: Bool {
        isEnabled(service: SMAppService.mainApp)
    }

    static func isEnabled(service: any LoginItemServing) -> Bool {
        // Pending approval is still a requested registration. Showing it as Off
        // prevented users from cancelling that request through Settings.
        service.status == .enabled || service.status == .requiresApproval
    }

    static func setEnabled(_ isEnabled: Bool, service: any LoginItemServing = SMAppService.mainApp) throws {
        if isEnabled {
            if !self.isEnabled(service: service) {
                try service.register()
            }
        } else if self.isEnabled(service: service) {
            try service.unregister()
        }
    }
}
