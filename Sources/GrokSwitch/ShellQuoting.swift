import Foundation

/// Shared shell / AppleScript quoting helpers.
enum ShellQuoting {
    /// POSIX single-quote escaping for use in `export FOO=…` and `zsh -lc` commands.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a value for embedding inside an AppleScript double-quoted string.
    static func appleScriptStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
