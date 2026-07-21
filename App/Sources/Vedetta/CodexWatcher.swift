import CoreServices
import Foundation

/// Watches `~/.codex/sessions` for rollout changes and hands each touched
/// rollout file to a callback, so Codex cards update near-instantly instead of
/// waiting for the periodic pass. This is the compatibility signal for
/// pre-hook sessions; FSEvents coalesces bursts with its own latency window.
final class CodexWatcher {
    private var stream: FSEventStreamRef?
    private let root: String
    private let onRollout: (String) -> Void
    private let onIndex: (String) -> Void

    init(
        root: String,
        onRollout: @escaping (String) -> Void,
        onIndex: @escaping (String) -> Void
    ) {
        self.root = root
        self.onRollout = onRollout
        self.onIndex = onIndex
    }

    func start() {
        guard stream == nil else { return }
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // UseCFTypes makes eventPaths a CFArray of CFStrings (bridgeable to
        // [String]); without it FSEvents hands back a raw char**, and casting
        // that to NSArray crashes the moment the stream fires.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
        guard let info,
              let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
        let watcher = Unmanaged<CodexWatcher>.fromOpaque(info).takeUnretainedValue()
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            if path.contains("rollout-") && path.hasSuffix(".jsonl") {
                watcher.onRollout(path)
            } else if path.hasSuffix("/session_index.jsonl") {
                watcher.onIndex(path)
            }
        }
    }
}
