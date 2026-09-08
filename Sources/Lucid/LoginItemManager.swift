import Foundation
import ServiceManagement

/// Toggles "Open at Login" for the app via SMAppService.
/// Only works when the app runs as a proper .app bundle
/// (see Scripts/build_app.sh) launched from /Applications.
enum LoginItemManager {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
