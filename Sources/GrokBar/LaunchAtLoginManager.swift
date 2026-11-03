import ServiceManagement

@MainActor
struct LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        let status = SMAppService.mainApp.status
        if enabled, status != .enabled {
            try SMAppService.mainApp.register()
        } else if !enabled, status == .enabled || status == .requiresApproval {
            // .requiresApproval is still registered. Leaving it in place would turn the switch back on after approval.
            try SMAppService.mainApp.unregister()
        }
    }
}
