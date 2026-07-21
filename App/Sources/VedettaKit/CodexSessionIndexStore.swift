import Foundation

/// Incremental latest-title index for `session_index.jsonl`.
public struct CodexSessionIndexStore: Sendable {
    public private(set) var offset: UInt64 = 0
    public private(set) var titles: [String: String] = [:]
    private var fileIdentity: UInt64?
    private var pending = Data()

    public init() {}

    public mutating func read(from url: URL) throws -> [String: String] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        if fileIdentity != nil && (identity != fileIdentity || size < offset) {
            offset = 0
            pending.removeAll(keepingCapacity: true)
            titles.removeAll(keepingCapacity: true)
        }
        fileIdentity = identity

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let appended = try handle.readToEnd() ?? Data()
        offset += UInt64(appended.count)
        pending.append(appended)

        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let entry = object as? [String: Any],
                  let id = entry["id"] as? String, !id.isEmpty,
                  let name = entry["thread_name"] as? String, !name.isEmpty else { continue }
            titles[id] = name
        }
        return titles
    }
}
