import AppKit
import Foundation

/// Swaps the running app bundle for a verified new one. Every failure
/// path restores the previous bundle: the app must never end up missing.
/// The archive is written to disk and unpacked only after its signature
/// has been checked by the caller.
enum UpdateInstaller {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static var workDir: String { VedettaSetup.rootDir + "/updates" }

    static func install(archive: Data, expectedVersion: String) throws {
        let fm = FileManager.default
        let current = Bundle.main.bundlePath
        let staging = workDir + "/staging"
        try? fm.removeItem(atPath: staging)
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: staging) }

        let zipPath = staging + "/update.zip"
        try archive.write(to: URL(fileURLWithPath: zipPath))
        try run("/usr/bin/ditto", ["-x", "-k", zipPath, staging + "/unpacked"])

        let unpacked = staging + "/unpacked"
        guard let entry = (try? fm.contentsOfDirectory(atPath: unpacked))?
            .first(where: { $0.hasSuffix(".app") }) else {
            throw Failure("The archive contains no app bundle.")
        }
        let newApp = unpacked + "/" + entry
        try validate(bundleAt: newApp, expectedVersion: expectedVersion)

        // Keep the outgoing bundle until the new one is in place.
        let backup = workDir + "/previous.app"
        try? fm.removeItem(atPath: backup)
        try fm.moveItem(atPath: current, toPath: backup)
        do {
            try run("/usr/bin/ditto", [newApp, current])
        } catch {
            try? fm.removeItem(atPath: current)
            try? fm.moveItem(atPath: backup, toPath: current)
            throw Failure("Install failed and the previous version was restored.")
        }
        try? fm.removeItem(atPath: backup)
    }

    /// The unpacked bundle must be the app we expect, at the version the
    /// release claims, with an intact signature — a truncated or swapped
    /// payload never replaces a working install.
    private static func validate(bundleAt path: String, expectedVersion: String) throws {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
              info["CFBundleIdentifier"] as? String == "app.vedetta.macos" else {
            throw Failure("The downloaded bundle isn't Meowtch.")
        }
        guard info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw Failure("The downloaded bundle isn't version \(expectedVersion).")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", path])
    }

    /// Launches the freshly installed copy and quits this one.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", path]
        try? process.run()
        // Give launch services a moment to spawn the new instance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSApp.terminate(nil)
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure(detail.isEmpty
                ? "\((tool as NSString).lastPathComponent) failed."
                : detail)
        }
    }
}
