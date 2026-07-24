import Foundation
import Testing
@testable import VedettaKit

/// Il self-cleanup di Vibe Island 1.0.41 non è mai partito per un parse
/// error zsh nel launcher (heredoc JXA, riga 48): questi test garantiscono
/// che gli script generati da Vedetta siano sempre sintatticamente validi.
struct RuntimeScriptsTests {
    private func syntaxCheck(_ shell: String, script: String) throws -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vedetta-script-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("script.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-n", file.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @Test func launcherParsesCleanly() throws {
        #expect(try syntaxCheck("/bin/zsh", script: RuntimeScripts.launcher(
            bundlePath: "/Users/x/Code/vedetta/dist/Vedetta.app"
        )))
    }

    @Test func launcherParsesCleanlyWithAwkwardBundlePath() throws {
        // Spazi e caratteri speciali nel path del bundle non devono
        // rompere il quoting dello script.
        #expect(try syntaxCheck("/bin/zsh", script: RuntimeScripts.launcher(
            bundlePath: "/Users/x/My Apps/Vedetta (dev).app"
        )))
    }

    @Test func statusLineParsesCleanly() throws {
        #expect(try syntaxCheck("/bin/bash", script: RuntimeScripts.statusLine(
            cacheFile: "$HOME/.vedetta/cache/rl.json"
        )))
    }
}
