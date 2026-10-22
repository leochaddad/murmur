import Foundation
import ServiceManagement

/// Launch at login via SMAppService (macOS 13+). The system owns this state — it can be
/// changed in System Settings › General › Login Items — so it is read live, never cached.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        if requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
