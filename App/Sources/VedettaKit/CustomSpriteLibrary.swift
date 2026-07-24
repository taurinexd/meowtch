import Foundation

/// Per-state custom sprite GIFs in ~/.vedetta/custom-sprites/. Pure file
/// resolution: a state resolves to a URL only when its GIF exists, so
/// callers fall back to the mascot everywhere else. File names use the
/// SessionState case names (the enum is Int-backed).
public struct CustomSpriteLibrary: Sendable {
    public static let enabledKey = "customSpritesEnabled"
    public static let standard = CustomSpriteLibrary(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vedetta/custom-sprites", isDirectory: true)
    )

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func fileName(for state: SessionState) -> String {
        switch state {
        case .needsApproval: "needsApproval.gif"
        case .running: "running.gif"
        case .compacting: "compacting.gif"
        case .waitingForInput: "waitingForInput.gif"
        case .completed: "completed.gif"
        }
    }

    public func fileURL(for state: SessionState) -> URL {
        directory.appendingPathComponent(Self.fileName(for: state))
    }

    /// URL only when the GIF is actually there.
    public func url(for state: SessionState) -> URL? {
        let url = fileURL(for: state)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func install(_ source: URL, for state: SessionState) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = fileURL(for: state)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: source, to: dest)
        return dest
    }

    public func remove(for state: SessionState) throws {
        let dest = fileURL(for: state)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
    }
}
