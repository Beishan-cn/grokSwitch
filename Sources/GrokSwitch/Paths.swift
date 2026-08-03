import AppKit
import Foundation

enum Paths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var grokSwitchRoot: URL {
        home.appendingPathComponent(".grokswitch")
    }

    static var configFile: URL {
        grokSwitchRoot.appendingPathComponent("config.json")
    }

    static var activeEnvFile: URL {
        grokSwitchRoot.appendingPathComponent("active.env")
    }

    static var profilesRoot: URL {
        grokSwitchRoot.appendingPathComponent("profiles")
    }

    static var defaultGrokHome: URL {
        home.appendingPathComponent(".grok")
    }

    static var defaultGrokBinary: URL {
        defaultGrokHome.appendingPathComponent("bin/grok")
    }

    static var zshrc: URL {
        home.appendingPathComponent(".zshrc")
    }

    static func profileHome(id: String) -> URL {
        profilesRoot.appendingPathComponent(id)
    }

    /// Whether `path` (after tilde expansion + standardization) is strictly under `profilesRoot`.
    static func isManagedProfileHome(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        let root = profilesRoot.standardizedFileURL
        let rootPath = root.path
        let candidatePath = candidate.path
        // Must be a child of profilesRoot, not the root itself.
        guard candidatePath.hasPrefix(rootPath + "/") else { return false }
        let relative = String(candidatePath.dropFirst(rootPath.count + 1))
        // Single path component only (no nested escape via extra segments that leave root after standardize).
        return !relative.isEmpty && !relative.contains("/") && relative != ".." && !relative.hasPrefix("..")
    }

    /// Resolve the grok binary path for launching terminals.
    /// Prefers absolute paths; falls back to a login-interactive shell lookup.
    static func resolveGrokBinary() -> URL? {
        let candidates = [
            defaultGrokBinary,
            URL(fileURLWithPath: "/usr/local/bin/grok"),
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/.local/bin/grok"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }

        // Login + interactive so .zprofile and .zshrc PATH entries are visible.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v grok"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    // MARK: - Permissions

    static func ensureSecureDirectory(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func ensureSecureFile(_ url: URL, permissions: Int = 0o600) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }
}

/// Native folder picker for menu-bar / settings flows.
enum FolderPicker {
    /// Present an `NSOpenPanel` for a single directory. Returns `nil` if cancelled.
    @MainActor
    static func pickDirectory(
        message: String,
        prompt: String = "选择",
        startingAt: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.message = message
        if let startingAt {
            panel.directoryURL = startingAt
        } else if let auto = ProjectScanner.autoDetectedRoot() {
            panel.directoryURL = auto
        } else {
            panel.directoryURL = Paths.home
        }
        // Menu bar apps are often inactive; bring forward so the panel is usable.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
