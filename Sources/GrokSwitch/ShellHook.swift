import Foundation

enum ShellHook {
    static let beginMarker = "# >>> grokswitch >>>"
    static let endMarker = "# <<< grokswitch <<<"

    static var hookBlock: String {
        """
        \(beginMarker)
        # GrokSwitch: apply active GROK_HOME for new shells
        if [ -f "$HOME/.grokswitch/active.env" ]; then
          . "$HOME/.grokswitch/active.env"
        fi
        \(endMarker)
        """
    }

    /// Ensure ~/.zshrc sources GrokSwitch active.env. Returns true if file was modified.
    @discardableResult
    static func ensureInstalled() -> Bool {
        let zshrc = Paths.zshrc
        let fm = FileManager.default

        if !fm.fileExists(atPath: zshrc.path) {
            let content = hookBlock + "\n"
            do {
                try content.write(to: zshrc, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }

        guard var existing = try? String(contentsOf: zshrc, encoding: .utf8) else {
            return false
        }

        if existing.contains(beginMarker), existing.contains(endMarker) {
            // Already installed — refresh block in case format changed
            if let updated = replaceBlock(in: existing) {
                if updated != existing {
                    try? updated.write(to: zshrc, atomically: true, encoding: .utf8)
                    return true
                }
            }
            return false
        }

        if !existing.hasSuffix("\n") {
            existing += "\n"
        }
        existing += "\n" + hookBlock + "\n"
        do {
            try existing.write(to: zshrc, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static func replaceBlock(in text: String) -> String? {
        guard let startRange = text.range(of: beginMarker),
              let endRange = text.range(of: endMarker) else {
            return nil
        }
        // Expand end to end of line
        let afterEnd = endRange.upperBound
        let lineEnd: String.Index
        if let nl = text[afterEnd...].firstIndex(of: "\n") {
            lineEnd = text.index(after: nl)
        } else {
            lineEnd = text.endIndex
        }
        var result = text
        result.replaceSubrange(startRange.lowerBound..<lineEnd, with: hookBlock + "\n")
        return result
    }
}
