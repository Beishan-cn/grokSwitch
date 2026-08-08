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

    /// Fallback app names for path probes.
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

    /// Executable names under Contents/MacOS for direct Process launch.
    var macOSExecutableNames: [String] {
        switch self {
        case .terminal: return ["Terminal"]
        case .iTerm2: return ["iTerm2"]
        case .ghostty: return ["ghostty"]
        case .otty: return ["otty"]
        case .warp: return ["Warp"]
        case .alacritty: return ["alacritty"]
        case .kitty: return ["kitty"]
        case .wezTerm: return ["wezterm", "wezterm-gui"]
        case .hyper: return ["Hyper"]
        case .tabby: return ["Tabby"]
        }
    }

    /// Whether launching a command is expected to work reliably.
    var supportsReliableCommandLaunch: Bool {
        switch self {
        case .terminal, .iTerm2, .ghostty, .otty, .alacritty, .kitty, .wezTerm:
            return true
        case .warp, .hyper, .tabby:
            return false
        }
    }

    var isInstalled: Bool {
        resolvedAppURL() != nil
    }

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

    func resolvedExecutableURL() -> URL? {
        guard let appURL = resolvedAppURL() else { return nil }
        let macos = appURL.appendingPathComponent("Contents/MacOS")
        for name in macOSExecutableNames {
            let url = macos.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        // Fallback: first executable in MacOS.
        if let items = try? FileManager.default.contentsOfDirectory(atPath: macos.path) {
            for item in items {
                let url = macos.appendingPathComponent(item)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    static var installed: [TerminalApp] {
        allCases.filter { $0 == .terminal || $0.isInstalled }
    }
}

enum TerminalLauncher {
    enum LaunchError: LocalizedError {
        case scriptFailed(String)
        case appNotFound(String)
        case processFailed(String)
        case grokBinaryNotFound

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message):
                return message
            case .appNotFound(let name):
                return "找不到终端应用「\(name)」，请在设置中更换"
            case .processFailed(let message):
                return message
            case .grokBinaryNotFound:
                return "找不到 grok 可执行文件（请确认已安装 Grok CLI，或将 grok 加入 PATH）"
            }
        }
    }

    /// Result of a launch attempt for honest UI messaging.
    enum LaunchOutcome: Equatable {
        case launched
        case launchedWithWarning(String)
        case bestEffort(String)
    }

    @discardableResult
    static func open(profile: Profile, terminal: TerminalApp, projectPath: String? = nil) throws -> LaunchOutcome {
        let homeURL = profile.homeURL.standardizedFileURL
        let home = homeURL.path
        guard Paths.isManagedProfileHome(home) else {
            throw LaunchError.processFailed("账号路径非法")
        }
        guard let binary = Paths.resolveGrokBinary(profileHome: homeURL) else {
            throw LaunchError.grokBinaryNotFound
        }

        let cwd = resolveCwd(projectPath)
        var warnings: [String] = []
        if let projectPath, !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, cwd == nil {
            warnings.append("项目路径无效，已忽略 --cwd")
        }

        let cwdArg = cwd.map { " --cwd \(ShellQuoting.shellSingleQuoted($0))" } ?? ""
        // PATH: prefer this profile's bin (auto_update target) over shared ~/.grok/bin.
        let binPath = homeURL.appendingPathComponent("bin").path
        let command = [
            "export GROK_HOME=\(ShellQuoting.shellSingleQuoted(home))",
            "export PATH=\(ShellQuoting.shellSingleQuoted(binPath)):\"$PATH\"",
            "exec \(ShellQuoting.shellSingleQuoted(binary.path))\(cwdArg)",
        ].joined(separator: "; ")

        switch terminal {
        case .terminal:
            try openInTerminalApp(command: command)
        case .iTerm2:
            try openInITerm(command: command)
        case .otty:
            try openInOtty(command: command)
        case .ghostty:
            try openDirectOrOpenArgs(
                app: terminal,
                directArgs: ["-e", "/bin/zsh", "-lic", command],
                openArgs: ["-e", "/bin/zsh", "-lic", command]
            )
        case .alacritty:
            try openDirectOrOpenArgs(
                app: terminal,
                directArgs: ["-e", "/bin/zsh", "-lic", command],
                openArgs: ["-e", "/bin/zsh", "-lic", command]
            )
        case .kitty:
            try openDirectOrOpenArgs(
                app: terminal,
                directArgs: ["/bin/zsh", "-lic", command],
                openArgs: ["/bin/zsh", "-lic", command]
            )
        case .wezTerm:
            try openDirectOrOpenArgs(
                app: terminal,
                directArgs: ["start", "--", "/bin/zsh", "-lic", command],
                openArgs: ["start", "--", "/bin/zsh", "-lic", command]
            )
        case .warp, .hyper, .tabby:
            return try openBestEffort(app: terminal, profile: profile)
        }

        if let warning = warnings.first {
            return .launchedWithWarning(warning)
        }
        return .launched
    }

    // MARK: - Terminal.app

    private static func openInTerminalApp(command: String) throws {
        let script = """
        tell application "Terminal"
            activate
            do script "\(ShellQuoting.appleScriptStringLiteral(command))"
        end tell
        """
        try runAppleScript(script)
    }

    // MARK: - iTerm2

    private static func openInITerm(command: String) throws {
        let script = """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text "\(ShellQuoting.appleScriptStringLiteral(command))"
            end tell
        end tell
        """
        try runAppleScript(script)
    }

    // MARK: - Otty

    private static func resolveOttyCLI() -> URL? {
        if let appURL = TerminalApp.otty.resolvedAppURL() {
            let bundled = appURL.appendingPathComponent("Contents/MacOS/otty-cli")
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
        try runProcess(executable: cli, arguments: ["open", "--command", command, "--quiet"])
    }

    // MARK: - Direct binary preferred

    private static func openDirectOrOpenArgs(app: TerminalApp, directArgs: [String], openArgs: [String]) throws {
        if let exe = app.resolvedExecutableURL() {
            do {
                // Ghostty / Alacritty / Kitty / WezTerm stay alive for the window lifetime.
                // Never waitUntilExit on the main thread — that freezes the whole app.
                try runProcess(executable: exe, arguments: directArgs, waitForExit: false)
                return
            } catch {
                // Fall through to open(1).
            }
        }
        try openWithOpenArgs(app: app, args: openArgs)
    }

    private static func openWithOpenArgs(app: TerminalApp, args: [String]) throws {
        guard let appURL = app.resolvedAppURL() else {
            throw LaunchError.appNotFound(app.displayName)
        }

        do {
            // open(1) returns once the app is asked to launch — safe to wait.
            try runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["-na", appURL.path, "--args"] + args,
                waitForExit: true
            )
        } catch {
            try runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["-a", appURL.path, "--args"] + args,
                waitForExit: true
            )
        }
    }

    /// Warp / Hyper / Tabby: open the app only; GROK_HOME comes from shell hook for new shells.
    private static func openBestEffort(app: TerminalApp, profile: Profile) throws -> LaunchOutcome {
        guard let appURL = app.resolvedAppURL() else {
            throw LaunchError.appNotFound(app.displayName)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // Fire-and-forget: blocking on the open callback freezes Settings / MenuBar on the main actor.
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
        return .bestEffort(
            "已打开 \(app.displayName)。该终端无法可靠注入启动命令；新 shell 将使用当前 active 的 GROK_HOME（\(profile.name)）。请手动运行 grok。"
        )
    }

    // MARK: - Helpers

    private static func resolveCwd(_ projectPath: String?) -> String? {
        guard let raw = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return expanded
    }

    /// - Parameter waitForExit: When false, only waits briefly for immediate spawn failure.
    ///   Long-lived terminal GUIs (Ghostty etc.) must use false — waiting blocks until the window closes.
    private static func runProcess(
        executable: URL,
        arguments: [String],
        waitForExit: Bool = true
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
            if waitForExit {
                process.waitUntilExit()
            } else {
                // Catch bad argv / missing dylib without owning the terminal session.
                let deadline = Date().addingTimeInterval(0.25)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning {
                    return
                }
            }
            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = (errText?.isEmpty == false)
                    ? errText!
                    : "进程退出码 \(process.terminationStatus)"
                throw LaunchError.processFailed(detail)
            }
        } catch let error as LaunchError {
            throw error
        } catch {
            throw LaunchError.processFailed(error.localizedDescription)
        }
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
}
