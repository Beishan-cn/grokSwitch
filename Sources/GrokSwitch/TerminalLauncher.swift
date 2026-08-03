import AppKit
import Foundation

enum TerminalLauncher {
    enum LaunchError: LocalizedError {
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message):
                return message
            }
        }
    }

    static func launchCommand(profile: Profile) -> String {
        let home = shellEscape(profile.homeURL.path)
        let binary = Paths.resolveGrokBinary()
        if binary.lastPathComponent == "env" {
            return "GROK_HOME=\(home) grok"
        }
        return "GROK_HOME=\(home) \(shellEscape(binary.path))"
    }

    static func open(profile: Profile) throws {
        let home = profile.homeURL.path
        let binary = Paths.resolveGrokBinary()
        let command: String
        if binary.lastPathComponent == "env" {
            command = "export GROK_HOME=\(shellEscape(home)); exec grok"
        } else {
            command = "export GROK_HOME=\(shellEscape(home)); exec \(shellEscape(binary.path))"
        }

        // Prefer Terminal.app via AppleScript for a reliable new window.
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapeForAppleScript(command))"
        end tell
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript 执行失败"
                throw LaunchError.scriptFailed(message)
            }
            return
        }
        throw LaunchError.scriptFailed("无法创建 AppleScript")
    }

    private static func shellEscape(_ value: String) -> String {
        // Single-quote shell escaping
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
