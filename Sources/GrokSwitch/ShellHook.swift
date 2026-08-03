import Foundation

/// Installs a small block into `~/.zshrc` that sources GrokSwitch `active.env`.
/// MVP: zsh only. bash/fish users must source `~/.grokswitch/active.env` manually.
enum ShellHook {
    static let beginMarker = "# >>> grokswitch >>>"
    static let endMarker = "# <<< grokswitch <<<"

    enum InstallResult: Equatable {
        case alreadyUpToDate
        case modified
        case failed(String)
    }

    static var hookBlock: String {
        """
        \(beginMarker)
        # GrokSwitch: apply active GROK_HOME for new shells (zsh only)
        if [ -f "$HOME/.grokswitch/active.env" ]; then
          . "$HOME/.grokswitch/active.env"
        fi
        \(endMarker)
        """
    }

    /// Ensure ~/.zshrc sources GrokSwitch active.env.
    @discardableResult
    static func ensureInstalled() -> InstallResult {
        let zshrc = Paths.zshrc
        let fm = FileManager.default

        if !fm.fileExists(atPath: zshrc.path) {
            let content = hookBlock + "\n"
            do {
                try content.write(to: zshrc, atomically: true, encoding: .utf8)
                return .modified
            } catch {
                return .failed("无法创建 ~/.zshrc：\(error.localizedDescription)")
            }
        }

        guard let existing = try? String(contentsOf: zshrc, encoding: .utf8) else {
            return .failed("无法读取 ~/.zshrc")
        }

        if existing.contains(beginMarker) || existing.contains(endMarker) {
            guard let updated = replaceBlock(in: existing) else {
                // Markers present but malformed — do not append a second block or corrupt the file.
                return .failed("检测到损坏的 grokswitch hook 标记（顺序异常或不成对），未修改 ~/.zshrc。请手动删除 # >>> grokswitch >>> … # <<< grokswitch <<< 块后重试。")
            }
            if updated == existing {
                return .alreadyUpToDate
            }
            do {
                try updated.write(to: zshrc, atomically: true, encoding: .utf8)
                return .modified
            } catch {
                return .failed("无法写入 ~/.zshrc：\(error.localizedDescription)")
            }
        }

        var next = existing
        if !next.hasSuffix("\n") {
            next += "\n"
        }
        next += "\n" + hookBlock + "\n"
        do {
            try next.write(to: zshrc, atomically: true, encoding: .utf8)
            return .modified
        } catch {
            return .failed("无法写入 ~/.zshrc：\(error.localizedDescription)")
        }
    }

    /// Replace the first well-ordered begin…end block. Returns nil if markers are malformed.
    static func replaceBlock(in text: String) -> String? {
        guard let startRange = text.range(of: beginMarker),
              let endRange = text.range(of: endMarker)
        else {
            return nil
        }
        // Require begin strictly before end to avoid illegal Range / swallowing mid-file content.
        guard startRange.lowerBound < endRange.lowerBound else {
            return nil
        }
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
