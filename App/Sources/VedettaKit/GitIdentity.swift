import Foundation

/// Reads the current git branch without spawning processes: walks up from
/// the directory to `.git` (directory, or file for worktrees) and parses
/// HEAD. Cheap enough to call on refresh passes.
public enum GitIdentity {
    public static func branch(forDirectory directory: String) -> String? {
        var current = directory as NSString
        for _ in 0..<10 {
            let gitPath = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) {
                let headPath: String
                if isDirectory.boolValue {
                    headPath = gitPath + "/HEAD"
                } else {
                    // worktree: .git is a file pointing at the real gitdir
                    guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8),
                          let line = content.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
                    else { return nil }
                    var gitdir = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    if !gitdir.hasPrefix("/") {
                        gitdir = (current.appendingPathComponent(gitdir) as NSString).standardizingPath
                    }
                    headPath = gitdir + "/HEAD"
                }
                guard let head = try? String(contentsOfFile: headPath, encoding: .utf8) else { return nil }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") {
                    return String(trimmed.dropFirst("ref: refs/heads/".count))
                }
                return String(trimmed.prefix(7))  // detached HEAD
            }
            let parent = current.deletingLastPathComponent as NSString
            if parent as String == current as String { break }
            current = parent
        }
        return nil
    }
}
