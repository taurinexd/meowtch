import Foundation

/// The session's task list as rebuilt from the transcript.
public struct SessionTasks: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var id: String
        public var subject: String
        public var status: String  // pending | in_progress | completed

        public init(id: String, subject: String, status: String) {
            self.id = id
            self.subject = subject
            self.status = status
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    public var done: [Item] { items.filter { $0.status == "completed" } }
    public var open: [Item] { items.filter { $0.status == "pending" } }
    public var inProgress: [Item] { items.filter { $0.status == "in_progress" } }
    public var isEmpty: Bool { items.isEmpty }
}

/// Streaming full-file transcript scan: extracts what the bounded windows
/// can miss — the user-given session name and the task list, which are
/// scattered anywhere in the file. Line-oriented: only lines containing a
/// marker are JSON-decoded.
public enum TranscriptFullScan {
    public struct Result: Sendable {
        public var sessionName: String?
        public var tasks: SessionTasks?
    }

    public static func run(path: String) -> Result {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Result() }
        defer { try? handle.close() }

        var result = Result()
        var items: [String: SessionTasks.Item] = [:]
        var order: [String] = []

        let nameMarker = Data("The user named this session".utf8)
        let createMarker = Data("created successfully:".utf8)
        let updateMarker = Data(#""name":"TaskUpdate""#.utf8)

        var carry = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            carry.append(chunk)
            while let newline = carry.firstIndex(of: 0x0A) {
                let line = carry.prefix(upTo: newline)
                processLine(
                    Data(line),
                    nameMarker: nameMarker, createMarker: createMarker,
                    updateMarker: updateMarker,
                    result: &result, items: &items, order: &order
                )
                carry = Data(carry.suffix(from: newline + 1))
            }
        }
        if !carry.isEmpty {
            processLine(
                carry,
                nameMarker: nameMarker, createMarker: createMarker,
                updateMarker: updateMarker,
                result: &result, items: &items, order: &order
            )
        }

        let ordered = order.compactMap { items[$0] }
        if !ordered.isEmpty {
            result.tasks = SessionTasks(items: ordered)
        }
        return result
    }

    private static func processLine(
        _ line: Data,
        nameMarker: Data, createMarker: Data, updateMarker: Data,
        result: inout Result,
        items: inout [String: SessionTasks.Item],
        order: inout [String]
    ) {
        let hasName = line.range(of: nameMarker) != nil
        let hasCreate = line.range(of: createMarker) != nil
        let hasUpdate = line.range(of: updateMarker) != nil
        guard hasName || hasCreate || hasUpdate else { return }

        guard let object = try? JSONSerialization.jsonObject(with: line),
              let entry = object as? [String: Any] else { return }
        guard entry["isSidechain"] as? Bool != true else { return }

        // A genuine rename reminder STARTS with the marker; the same words
        // merely quoted inside tool output (e.g. a grep of another
        // transcript) appear mid-text and must not match.
        if hasName, let text = entryText(entry),
           text.hasPrefix("<system-reminder>\nThe user named this session \"") {
            let after = text.dropFirst("<system-reminder>\nThe user named this session \"".count)
            if let close = after.firstIndex(of: "\"") {
                result.sessionName = String(after[..<close])
            }
        }

        if hasCreate, let text = entryText(entry) {
            // "Task #12 created successfully: Subject line"
            for lineText in text.split(separator: "\n") {
                guard let range = lineText.range(of: #"Task #(\d+) created successfully: "#, options: .regularExpression) else { continue }
                let idPart = lineText[range].dropFirst(6).prefix { $0.isNumber }
                let subject = String(lineText[range.upperBound...])
                let id = String(idPart)
                guard !id.isEmpty, !subject.isEmpty, items[id] == nil else { continue }
                items[id] = SessionTasks.Item(id: id, subject: subject, status: "pending")
                order.append(id)
            }
        }

        if hasUpdate {
            for block in toolUseBlocks(entry) where block["name"] as? String == "TaskUpdate" {
                guard let input = block["input"] as? [String: Any],
                      let id = (input["taskId"] as? String)
                        ?? (input["taskId"] as? NSNumber)?.stringValue else { continue }
                if var item = items[id] {
                    if let status = input["status"] as? String {
                        if status == "deleted" {
                            items.removeValue(forKey: id)
                            order.removeAll { $0 == id }
                            continue
                        }
                        item.status = status
                    }
                    if let subject = input["subject"] as? String { item.subject = subject }
                    items[id] = item
                }
            }
        }
    }

    private static func entryText(_ entry: [String: Any]) -> String? {
        guard let message = entry["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        var parts: [String] = []
        for block in blocks {
            if let text = block["text"] as? String { parts.append(text) }
            if block["type"] as? String == "tool_result" {
                if let content = block["content"] as? String { parts.append(content) }
                if let sub = block["content"] as? [[String: Any]] {
                    parts.append(contentsOf: sub.compactMap { $0["text"] as? String })
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func toolUseBlocks(_ entry: [String: Any]) -> [[String: Any]] {
        guard let message = entry["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return [] }
        return blocks.filter { $0["type"] as? String == "tool_use" }
    }
}
