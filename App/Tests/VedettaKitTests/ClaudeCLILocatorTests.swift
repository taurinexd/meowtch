import Testing
@testable import VedettaKit

struct ClaudeCLILocatorTests {
    @Test func findsTheNativeInstallWithoutAShell() {
        // The native installer puts `claude` in ~/.local/bin and adds that
        // to PATH only in .zshrc — invisible to a `zsh -lc` spawned by an
        // app launched from Finder (the "isn't on your PATH" bug).
        let path = ClaudeCLILocator.firstKnownInstall(home: "/Users/x") {
            $0 == "/Users/x/.local/bin/claude"
        }
        #expect(path == "/Users/x/.local/bin/claude")
    }

    @Test func prefersTheNativeInstallOverHomebrew() {
        let path = ClaudeCLILocator.firstKnownInstall(home: "/Users/x") { _ in true }
        #expect(path == "/Users/x/.local/bin/claude")
    }

    @Test func nilWhenNoKnownLocationHasIt() {
        #expect(ClaudeCLILocator.firstKnownInstall(home: "/Users/x") { _ in false } == nil)
    }

    @Test func shellOutputTakesTheLastAbsolutePath() {
        // An interactive shell may print .zshrc chatter before the answer.
        let output = "Welcome back!\n/opt/custom/bin/claude\n"
        #expect(ClaudeCLILocator.parseCommandV(output) == "/opt/custom/bin/claude")
    }

    @Test func shellOutputIgnoresAliasesAndNoise() {
        // `command -v` prints an alias definition, not a path, for aliases.
        #expect(ClaudeCLILocator.parseCommandV("alias claude='claude --x'\n") == nil)
        #expect(ClaudeCLILocator.parseCommandV("") == nil)
    }
}
