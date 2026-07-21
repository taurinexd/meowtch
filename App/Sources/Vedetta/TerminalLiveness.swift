import Darwin
import Foundation
import VedettaKit

/// System-level probes for the liveness sweep: is a pid alive, and is it
/// still attached to a given tty (controlling terminal). Both read kernel
/// state directly — no subprocesses on the 15s timer path.
enum TerminalLiveness {
    static func isProcessAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// True when `pid` is alive and its controlling terminal is the device
    /// at `tty`. A killed terminal tab tears both down; a recycled tty name
    /// belongs to processes outside the session's ancestry.
    static func isPidAttachedToTTY(_ pid: Int, _ tty: String) -> Bool {
        guard let dev = ttyDevice(path: tty),
              let controlling = controllingTTYDevice(of: pid) else { return false }
        return dev == controlling
    }

    private static func ttyDevice(path: String) -> dev_t? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return status.st_rdev
    }

    private static func controllingTTYDevice(of pid: Int) -> dev_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != DEV_T_NODEV else { return nil }
        return dev
    }

    /// kinfo_proc reports "no controlling terminal" as (dev_t)-1.
    private static let DEV_T_NODEV: dev_t = -1
}
