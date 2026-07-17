import CoreGraphics
import Foundation

// vedetta-bridge — invoked by agent CLI hooks. Reads the hook payload from
// stdin, wraps it in an envelope with the terminal identity (the hook runs
// inside the terminal's process context), sends it to the app's Unix
// socket and prints the app's reply to stdout (empty object when the app
// has nothing to say). Exits 0 in every failure mode: a missing or busy
// app must never slow down or break the agent.

let socketPath = ("~/.vedetta/run/vedetta.sock" as NSString).expandingTildeInPath

func argument(after flag: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func terminalIdentity() -> [String: Any] {
    var info: [String: Any] = [:]
    let env = ProcessInfo.processInfo.environment
    // The tty: try our own fds first (stderr often still points at the
    // terminal), then walk up to the parent.
    for fd: Int32 in [2, 1, 0] {
        if let name = ttyname(fd) {
            info["tty"] = String(cString: name)
            break
        }
    }
    if let termProgram = env["TERM_PROGRAM"] { info["termProgram"] = termProgram }
    if let termSession = env["TERM_SESSION_ID"] { info["termSessionId"] = termSession }
    if let bundle = env["__CFBundleIdentifier"] { info["bundleIdentifier"] = bundle }
    if env["VSCODE_INJECTION"] != nil || env["TERM_PROGRAM"] == "vscode" {
        info["isVSCode"] = true
    }
    info["pid"] = Int(getpid())
    info["ppid"] = Int(getppid())
    if let windowId = frontWindowIdOfOwningApp() {
        info["windowId"] = windowId
    }
    return info
}

/// Parent pid via sysctl — the hook environment has no /proc.
func parentPid(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// The window that hosts this session: our process ancestry leads to the
/// terminal app (VS Code's shells hang off its helper processes), and its
/// frontmost on-screen window at hook time is where the user is typing —
/// the app trusts this only on user-driven events. Nil when there is no
/// window-server access (SSH) or no window is on screen.
func frontWindowIdOfOwningApp() -> Int? {
    var chain = Set<pid_t>()
    var current = getpid()
    for _ in 0..<30 {
        chain.insert(current)
        guard let parent = parentPid(of: current), parent > 1 else { break }
        current = parent
    }
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return nil }
    // Front-to-back: the first normal-layer window owned by an ancestor.
    for entry in list {
        guard (entry[kCGWindowLayer as String] as? Int) == 0,
              let owner = entry[kCGWindowOwnerPID as String] as? Int,
              chain.contains(pid_t(owner)),
              let id = entry[kCGWindowNumber as String] as? Int else { continue }
        return id
    }
    return nil
}

// 1. Read the hook payload.
let inputData = FileHandle.standardInput.readDataToEndOfFile()
let payload = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] ?? [:]

// 2. Build the envelope.
let envelope: [String: Any] = [
    "v": 1,
    "source": argument(after: "--source") ?? "claude",
    "terminal": terminalIdentity(),
    "event": payload,
]
guard var data = try? JSONSerialization.data(withJSONObject: envelope) else { exit(0) }
data.append(0x0A)

// 3. Connect. On a Unix socket this either succeeds immediately or fails
//    with ECONNREFUSED/ENOENT — no timeout gymnastics needed.
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = socketPath.utf8CString
guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
}
let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { exit(0) }

// 4. Send, half-close, then wait for the reply. No read timeout: for
//    blocking events (approvals) the app intentionally holds the line
//    until the user decides; Claude Code's own hook timeout is the cap.
data.withUnsafeBytes { raw in
    _ = write(fd, raw.baseAddress, raw.count)
}
shutdown(fd, SHUT_WR)

var reply = Data()
var chunk = [UInt8](repeating: 0, count: 64 << 10)
while true {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { break }
    reply.append(contentsOf: chunk[0..<n])
    if chunk[0..<n].contains(0x0A) { break }
}
close(fd)

// 5. Relay a non-trivial reply to the hook caller (hook JSON output).
if let newline = reply.firstIndex(of: 0x0A) { reply = reply.prefix(upTo: newline) }
if reply.count > 2 {  // "{}" = nothing to say
    FileHandle.standardOutput.write(reply)
}
exit(0)
