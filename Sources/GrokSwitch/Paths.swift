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

    /// Resolve the grok binary path for launching terminals.
    static func resolveGrokBinary() -> URL {
        let candidates = [
            defaultGrokBinary,
            URL(fileURLWithPath: "/usr/local/bin/grok"),
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        // Fall back to PATH lookup via /usr/bin/env
        return URL(fileURLWithPath: "/usr/bin/env")
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
