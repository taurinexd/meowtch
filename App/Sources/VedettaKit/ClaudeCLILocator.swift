import Foundation

/// Where the `claude` binary lives. An app launched from Finder inherits
/// launchd's bare PATH, and `zsh -lc` reads .zprofile but NOT .zshrc —
/// which is exactly where the native installer adds ~/.local/bin. So the
/// known install locations are checked directly first; the caller falls
/// back to an interactive shell's `command -v` only when none match.
public enum ClaudeCLILocator {
    /// Probe order: native installer, the old npm-local install, Homebrew
    /// (arm64, then Intel), npm/bun global prefixes.
    public static func knownInstalls(home: String) -> [String] {
        [
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.npm-global/bin/claude",
            home + "/.bun/bin/claude",
        ]
    }

    public static func firstKnownInstall(
        home: String, isExecutable: (String) -> Bool
    ) -> String? {
        knownInstalls(home: home).first(where: isExecutable)
    }

    /// The path in a shell's `command -v claude` output: the last line that
    /// is an absolute path (shell startup files may print before it; an
    /// alias or function prints no path at all).
    public static func parseCommandV(_ output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }
}
