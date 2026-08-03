import AppKit
import Foundation

/// Known terminal apps we can launch with a command.
enum TerminalApp: String, Codable, CaseIterable, Identifiable, Equatable {
    case terminal
    case iTerm2
    case ghostty
    case otty
    case warp
    case alacritty
    case kitty
    case wezTerm
    case hyper
    case tabby

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .otty: return "Otty"
        case .warp: return "Warp"
        case .alacritty: return "Alacritty"
        case .kitty: return "Kitty"
        case .wezTerm: return "WezTerm"
        case .hyper: return "Hyper"
        case .tabby: return "Tabby"
        }
    }

    /// Bundle identifiers used to locate the app on disk.
    var bundleIdentifiers: [String] {
        switch self {
        case .terminal: return ["com.apple.Terminal"]
        case .iTerm2: return ["com.googlecode.iterm2"]
        case .ghostty: return ["com.mitchellh.ghostty"]
        case .otty: return ["io.appmakes.otty"]
        case .warp: return ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        case .alacritty: return ["org.alacritty", "io.alacritty"]
        case .kitty: return ["net.kovidgoyal.kitty"]
        case .wezTerm: return ["com.github.wez.wezterm"]
        case .hyper: return ["co.zeit.hyper"]
        case .tabby: return ["org.tabby"]
        }
    }

    /// Fallback app names for `open -na`.
    var appNames: [String] {
        switch self {
        case .terminal: return ["Terminal"]
        case .iTerm2: return ["iTerm", "iTerm2"]
        case .ghostty: return ["Ghostty"]
        case .otty: return ["Otty"]
        case .warp: return ["Warp"]
        case .alacritty: return ["Alacritty"]
        case .kitty: return ["kitty"]
        case .wezTerm: return ["WezTerm"]
        case .hyper: return ["Hyper"]
        case .tabby: return ["Tabby"]
        }
    }

    /// Whether this app appears to be installed.
    var isInstalled: Bool {
        resolvedAppURL() != nil
    }

    /// Resolve the .app URL if installed.
    func resolvedAppURL() -> URL? {
        let workspace = NSWorkspace.shared
        for bundleID in bundleIdentifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }
        for name in appNames {
            let candidates = [
                "/Applications/\(name).app",
                "\(NSHomeDirectory())/Applications/\(name).app",
            ]
            for path in candidates where FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// All installed terminal apps (Terminal is always considered available).
    static var installed: [TerminalApp] {
        allCases.filter { $0 == .terminal || $0.isInstalled }
    }
}

enum TerminalLauncher {
    enum LaunchError: LocalizedError {
        case scriptFailed(String)
        case appNotFound(String)
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message):
                return message
            case .appNotFound(let name):
                return "找不到终端应用「\(name)」，请在设置中更换"
            case .processFailed(let message):
                return message
            }
        }
    }

    static func open(profile: Profile, terminal: TerminalApp, projectPath: String? = nil) throws {
        let home = profile.homeURL.path
        let binary = Paths.resolveGrokBinary()
        let cwdArg = cwdArgument(projectPath)
        let command: String
        if binary.lastPathComponent == "env" {
            command = "export GROK_HOME=\(shellEscape(home)); exec grok\(cwdArg)"
        } else {
            command = "export GROK_HOME=\(shellEscape(home)); exec \(shellEscape(binary.path))\(cwdArg)"
        }

        switch terminal {
        case .terminal:
            try openInTerminalApp(command: command)
        case .iTerm2:
            try openInITerm(command: command)
        case .ghostty:
            try openWithOpenArgs(app: terminal, args: ["-e", "/bin/zsh", "-lc", command])
        case .otty:
            try openInOtty(command: command)
        case .warp:
            // Warp has limited CLI; open a login shell that immediately runs the command.
            try openWithOpenArgs(app: terminal, args: ["--", "/bin/zsh", "-lc", command])
        case .alacritty:
            try openWithOpenArgs(app: terminal, args: ["-e", "/bin/zsh", "-lc", command])
        case .kitty:
            try openWithOpenArgs(app: terminal, args: ["/bin/zsh", "-lc", command])
        case .wezTerm:
            try openWithOpenArgs(app: terminal, args: ["start", "--", "/bin/zsh", "-lc", command])
        case .hyper, .tabby:
            // Best-effort: open the app; GROK_HOME still comes from shell hook for new shells.
            // Prefer a temp script when possible.
            try openViaTempScript(app: terminal, command: command)
        }
    }

    // MARK: - Terminal.app

    private static func openInTerminalApp(command: String) throws {
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapeForAppleScript(command))"
        end tell
        """
        try runAppleScript(script)
    }

    // MARK: - iTerm2

    private static func openInITerm(command: String) throws {
        // Create a new window and run the command in its session.
        let script = """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text "\(escapeForAppleScript(command))"
            end tell
        end tell
        """
        try runAppleScript(script)
    }

    // MARK: - Otty

    /// Resolve Otty's control CLI (`otty-cli` inside the app, or `otty` on PATH).
    private static func resolveOttyCLI() -> URL? {
        if let appURL = TerminalApp.otty.resolvedAppURL() {
            let bundled = appURL
                .appendingPathComponent("Contents/MacOS/otty-cli")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        let pathCandidates = [
            "/usr/local/bin/otty",
            "/opt/homebrew/bin/otty",
            "\(NSHomeDirectory())/.local/bin/otty",
        ]
        for path in pathCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func openInOtty(command: String) throws {
        guard let cli = resolveOttyCLI() else {
            throw LaunchError.appNotFound("Otty")
        }
        // Otty CLI: `otty open --command '…'` launches a new window with that command.
        let process = Process()
        process.executableURL = cli
        process.arguments = ["open", "--command", command, "--quiet"]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = (errText?.isEmpty == false)
                    ? errText!
                    : "otty 退出码 \(process.terminationStatus)"
                throw LaunchError.processFailed(detail)
            }
        } catch let error as LaunchError {
            throw error
        } catch {
            throw LaunchError.processFailed(error.localizedDescription)
        }
    }

    // MARK: - open -na App --args …

    private static func openWithOpenArgs(app: TerminalApp, args: [String]) throws {
        guard let appURL = app.resolvedAppURL() else {
            throw LaunchError.appNotFound(app.displayName)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -n: new instance/window path; -a: application
        process.arguments = ["-na", appURL.path, "--args"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                // Some apps ignore -n; retry without -n.
                try openWithOpenArgsRetry(appURL: appURL, args: args)
            }
        } catch {
            throw LaunchError.processFailed(error.localizedDescription)
        }
    }

    private static func openWithOpenArgsRetry(appURL: URL, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appURL.path, "--args"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw LaunchError.processFailed("open 退出码 \(process.terminationStatus)")
        }
    }

    // MARK: - Temp script fallback

    private static func openViaTempScript(app: TerminalApp, command: String) throws {
        guard let appURL = app.resolvedAppURL() else {
            throw LaunchError.appNotFound(app.displayName)
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grokswitch-\(UUID().uuidString).command")
        let scriptBody = """
        #!/bin/zsh
        \(command)

        """
        try scriptBody.write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: tmp.path
        )

        // Opening a .command file typically uses Terminal; for other apps, open the app
        // and hope the user has shell hook. Prefer running zsh -lc via open when possible.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", appURL.path, "--args", "-e", "/bin/zsh", tmp.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                // Last resort: open Terminal with the script (macOS runs .command in Terminal).
                NSWorkspace.shared.open(tmp)
            }
        } catch {
            NSWorkspace.shared.open(tmp)
        }
    }

    // MARK: - Helpers

    /// Returns ` --cwd '…'` when a valid project path is set, otherwise empty.
    private static func cwdArgument(_ projectPath: String?) -> String {
        guard let raw = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return ""
        }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else {
            return ""
        }
        return " --cwd \(shellEscape(expanded))"
    }

    private static func runAppleScript(_ source: String) throws {
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else {
            throw LaunchError.scriptFailed("无法创建 AppleScript")
        }
        appleScript.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript 执行失败"
            throw LaunchError.scriptFailed(message)
        }
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
