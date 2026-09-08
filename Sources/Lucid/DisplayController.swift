import Foundation

/// Turns off the display immediately instead of waiting for the
/// configured display-sleep timer. Uses the public `pmset` command
/// (`pmset displaysleepnow`), which works as a regular user without sudo.
/// macOS handles waking the display on keyboard/mouse activity
/// automatically afterwards – no custom code needed for that.
enum DisplayController {

    enum DisplayControllerError: LocalizedError {
        case commandFailed(status: Int32)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let status):
                return "pmset displaysleepnow failed with status \(status)."
            }
        }
    }

    static func sleepNow() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DisplayControllerError.commandFailed(status: process.terminationStatus)
        }
    }
}
