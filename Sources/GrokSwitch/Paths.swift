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
