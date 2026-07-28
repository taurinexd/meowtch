import Foundation

/// Unix-domain socket server receiving one JSON envelope per connection
/// from the hook bridge. The reply (another JSON line) is what makes
/// blocking flows possible: for approvals (M3) the handler will suspend
/// until the user decides from the notch.
final class EventServer: @unchecked Sendable {
    /// Raw bytes in, raw bytes out: only Sendable types cross the actor
    /// boundary; JSON is decoded on the receiving side.
    typealias Handler = @Sendable (Data) async -> Data

    private let socketPath: String
    private let handler: Handler
    private var socketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "app.vedetta.eventserver")
    /// Filesystem identity of the socket file this instance created, so
    /// teardown can tell it apart from a successor's.
    private var boundFile: (dev: dev_t, ino: ino_t)?

    init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() throws {
        try FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        chmod(socketPath, 0o600)
        var created = stat()
        boundFile = stat(socketPath, &created) == 0
            ? (created.st_dev, created.st_ino)
            : nil
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        socketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            self.handleConnection(client)
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if socketFD >= 0 { close(socketFD) }
        socketFD = -1
        // Remove the socket file only while it is still OURS. During an
        // auto-update relaunch both instances are briefly alive: the
        // successor rebinds the path, and unlinking it here would leave it
        // listening on an inode no client can reach — every hook would
        // silently fail to connect until the next manual restart.
        guard let boundFile else { return }
        var current = stat()
        guard stat(socketPath, &current) == 0,
              current.st_dev == boundFile.dev, current.st_ino == boundFile.ino
        else { return }
        unlink(socketPath)
    }

    /// Re-creates the socket file when it has vanished under us — an older
    /// instance tearing down after an auto-update relaunch used to remove
    /// it, leaving this process listening where nothing can reach it. Only
    /// acts when the path is ABSENT: a foreign socket there belongs to
    /// another live instance and is left alone.
    func ensureListening() {
        guard boundFile != nil else { return }
        var current = stat()
        guard stat(socketPath, &current) != 0 else { return }
        acceptSource?.cancel()
        acceptSource = nil
        if socketFD >= 0 { close(socketFD) }
        socketFD = -1
        boundFile = nil
        try? start()
    }

    // MARK: - Connection

    private func handleConnection(_ client: Int32) {
        // Read on a background task: connections are short-lived
        // (one envelope in, one reply out).
        Task.detached { [handler] in
            defer { close(client) }
            guard let data = Self.readLine(from: client, maxBytes: 4 << 20) else { return }
            var out = await handler(data)
            out.append(0x0A)
            out.withUnsafeBytes { raw in
                _ = write(client, raw.baseAddress, raw.count)
            }
        }
    }

    /// Reads until newline or EOF, bounded by maxBytes.
    private static func readLine(from fd: Int32, maxBytes: Int) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while buffer.count < maxBytes {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break }
        }
        guard !buffer.isEmpty else { return nil }
        if let newline = buffer.firstIndex(of: 0x0A) {
            buffer = buffer.prefix(upTo: newline)
        }
        return buffer
    }
}
