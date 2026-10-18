import Foundation
import VedettaKit

/// Resolves and runs the `claude` CLI from a Finder-launched app, whose
/// PATH is launchd's bare one. Never rely on `zsh -lc "claude …"` finding
/// it: the native installer adds ~/.local/bin to PATH in .zshrc only.
enum ClaudeCLI {
    /// Absolute path to `claude`, or nil when it isn't installed. Known
    /// install locations first; then an interactive login shell (which
    /// does read .zshrc) for custom setups. Blocks; call off the main
    /// thread when the fallback may run.
    static func resolve() -> String? {
        if let hit = ClaudeCLILocator.firstKnownInstall(
            home: NSHomeDirectory(),
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        ) {
            return hit
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-ilc", "command -v claude"]
        shell.standardInput = FileHandle.nullDevice
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = Pipe()
        guard (try? shell.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        guard let path = ClaudeCLILocator.parseCommandV(String(decoding: data, as: UTF8.self)),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// `zsh -lc` arguments that run the resolved binary by absolute path,
    /// with its directory prepended to PATH (an npm install's `env node`
    /// shebang finds the node that sits next to it).
    static func shellArguments(_ binary: String, _ arguments: String) -> [String] {
        let dir = shellQuote((binary as NSString).deletingLastPathComponent)
        return ["-lc", "PATH=\(dir):$PATH \(shellQuote(binary)) \(arguments)"]
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
