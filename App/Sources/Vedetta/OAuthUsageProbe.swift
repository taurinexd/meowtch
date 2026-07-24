import Foundation
import VedettaKit

/// Opt-in quota probe: reads the account's OAuth access token from the
/// Claude Code Keychain item (or .credentials.json) and asks the same
/// endpoint /usage uses. Read-only: never refreshes tokens — an expired
/// token just means the account shows as stale until one of its sessions
/// runs. Undocumented endpoint; the User-Agent must look like the CLI or
/// the request lands in a throttled bucket.
enum OAuthUsageProbe {
    enum ProbeResult {
        case success(AccountQuota.Sample)
        case rateLimited(retryAfter: TimeInterval?)
        case unavailable
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Version for the User-Agent: the real CLI's if discoverable, else a
    /// recent known-good pinned one.
    private static let userAgent: String = {
        let pinned = "2.1.218"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "claude --version 2>/dev/null"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "claude-code/\(pinned)" }
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // "2.1.218 (Claude Code)" → "2.1.218"
        let version = output.split(separator: " ").first.map(String.init) ?? ""
        return "claude-code/\(version.isEmpty ? pinned : version)"
    }()

    static func fetch(account: ClaudeAccount) async -> ProbeResult {
        guard let credentials = readCredentials(for: account),
              !credentials.isExpired(now: Date()) else { return .unavailable }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .unavailable }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        }
        guard http.statusCode == 200 else { return .unavailable }
        let parsed = RateLimitHarvest.windows(from: data)
        guard parsed.fiveHour != nil || parsed.sevenDay != nil else { return .unavailable }
        return .success(AccountQuota.Sample(
            fiveHour: parsed.fiveHour, sevenDay: parsed.sevenDay,
            at: Date(), origin: .pull
        ))
    }

    /// Tries each locator candidate in order: keychain items via the
    /// `security` CLI (the proven pattern — may prompt once per item, the
    /// user can choose Always Allow), then the credentials file.
    private static func readCredentials(for account: ClaudeAccount) -> ClaudeCredentials? {
        for candidate in ClaudeCredentialLocator.candidates(
            configDir: account.path, isDefault: account.isDefault
        ) {
            switch candidate {
            case .keychainService(let service):
                if let data = keychainRead(service: service),
                   let credentials = ClaudeCredentials.parse(data) {
                    return credentials
                }
            case .credentialsFile(let path):
                if let data = FileManager.default.contents(atPath: path),
                   let credentials = ClaudeCredentials.parse(data) {
                    return credentials
                }
            }
        }
        return nil
    }

    private static func keychainRead(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-s", service, "-a", NSUserName(), "-w",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        if text.hasPrefix("{") { return Data(text.utf8) }
        // `security -w` prints hex for binary-typed values.
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex,
              let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) {
            guard let byte = UInt8(text[index..<next], radix: 16) else {
                return Data(text.utf8)
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
