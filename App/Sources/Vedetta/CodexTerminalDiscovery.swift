import AppKit
import Darwin
import Foundation
import VedettaKit

/// Recovers the terminal for Codex sessions that predate hook installation.
/// VI does this by retaining the PID that owns the open rollout file
/// (`codexWriterPid`); on macOS its binary uses `/usr/sbin/lsof -F` for the
/// lookup. Hooks remain authoritative when they later provide an exact window.
enum CodexTerminalDiscovery {
    static func openRollouts() -> [String: TerminalInfo] {
        guard let output = lsofOutput() else { return [:] }
        return CodexOpenRolloutFiles.parse(lsofOutput: output).compactMapValues {
            CodexTerminalFallback.resolve(
                ownerPID: $0,
                parentOf: parentPID,
                bundleIdentifierOf: bundleIdentifier
            )
        }
    }

    private static func lsofOutput() -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-c", "codex", "-Fpn"]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func bundleIdentifier(of pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
