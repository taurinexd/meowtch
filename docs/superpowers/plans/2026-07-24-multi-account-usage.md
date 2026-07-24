# Multi-account Claude Usage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Usage realtime di 3+ account Claude nel notch (drill-down provider→account), gestione in Settings → Accounts, dati ibridi push statusline per-account + pull opt-in dall'endpoint `oauth/usage` — come da spec `docs/superpowers/specs/2026-07-24-multi-account-usage-design.md`.

**Architecture:** La logica pura (registry, hash/locator credenziali, parser rate-limits, merge push/pull, scheduler backoff) vive in **VedettaKit** con unit test; UsageModel/VedettaSetup/UI restano nell'app e la consumano. Il bridge tagga le sessioni con `CLAUDE_CONFIG_DIR`.

**Tech Stack:** Swift 6 / SwiftUI + AppKit, swift Testing (`import Testing`, `#expect`), CryptoKit (sha256), `security` CLI per il Keychain, URLSession per il probe opt-in.

## Global Constraints

- Build dal **root del repo**: `make app`; test: `make test` (mai `swift test` diretto).
- Commit **locali su `main`, MAI push**; un commit per task col messaggio indicato.
- Copy UI in inglese; risposta all'utente in italiano.
- **Zero rete di default**: l'unica connessione è il probe opt-in (`SettingsKey.claudeNetworkRefresh`, default `false`). Mai refresh dei token OAuth.
- Config di terzi (`settings.json` di ogni account): merge additivo con backup timestampato (pattern `configStore.mutate` esistente).
- `SessionState` è Int-backed; gli id account sono **path canonici** della config dir.
- Nulla è "fatto" senza giro live + conferma manuale di Matteo (Task 9).

---

### Task 1: ClaudeAccount + ClaudeAccountRegistry (VedettaKit)

**Files:**
- Create: `App/Sources/VedettaKit/ClaudeAccount.swift`
- Test: `App/Tests/VedettaKitTests/ClaudeAccountTests.swift`

**Interfaces:**
- Produces: `ClaudeAccount { path, alias, email, subscriptionType, isDefault, isAvailable }` (`Codable`, `Identifiable`, `id == path`); `ClaudeAccount.settingsPath`; `ClaudeAccountRegistry.resolve(defaultPath:stored:directoryExists:) -> [ClaudeAccount]`; `StoredClaudeAccount { path, alias, email, subscriptionType }` (`Codable`, il record persistito).

- [ ] **Step 1: Test che fallisce**

```swift
import Foundation
import Testing
@testable import VedettaKit

struct ClaudeAccountTests {
    @Test func defaultAccountIsAlwaysFirst() {
        let accounts = ClaudeAccountRegistry.resolve(
            defaultPath: "/Users/x/.claude",
            stored: [StoredClaudeAccount(path: "/Users/x/.claude-work")],
            directoryExists: { _ in true }
        )
        #expect(accounts.count == 2)
        #expect(accounts[0].isDefault)
        #expect(accounts[0].path == "/Users/x/.claude")
        #expect(!accounts[1].isDefault)
    }

    @Test func canonicalizesAndDeduplicates() {
        let accounts = ClaudeAccountRegistry.resolve(
            defaultPath: "/Users/x/.claude",
            stored: [
                StoredClaudeAccount(path: "/Users/x/.claude/"),          // duplica il default
                StoredClaudeAccount(path: "/Users/x/foo/../.claude-b"),  // da canonicalizzare
            ],
            directoryExists: { _ in true }
        )
        #expect(accounts.map(\.path) == ["/Users/x/.claude", "/Users/x/.claude-b"])
    }

    @Test func storedMetadataSurvivesResolve() {
        let accounts = ClaudeAccountRegistry.resolve(
            defaultPath: "/Users/x/.claude",
            stored: [StoredClaudeAccount(
                path: "/Users/x/.claude-b", alias: "Work",
                email: "w@x.com", subscriptionType: "max"
            )],
            directoryExists: { $0 == "/Users/x/.claude-b" }
        )
        #expect(accounts[1].alias == "Work")
        #expect(accounts[1].email == "w@x.com")
        #expect(accounts[1].subscriptionType == "max")
        #expect(accounts[1].isAvailable)
        #expect(!accounts[0].isAvailable)   // la dir default qui non esiste
    }

    @Test func settingsPathAndDisplayName() {
        let account = ClaudeAccount(
            path: "/Users/x/.claude-b", alias: nil, email: "w@x.com",
            subscriptionType: nil, isDefault: false, isAvailable: true
        )
        #expect(account.settingsPath == "/Users/x/.claude-b/settings.json")
        #expect(account.displayName == "w@x.com")
        let anonymous = ClaudeAccount(
            path: "/Users/x/.claude-b", alias: nil, email: nil,
            subscriptionType: nil, isDefault: false, isAvailable: true
        )
        #expect(anonymous.displayName == ".claude-b")
    }
}
```

- [ ] **Step 2: `make test` → FAIL** ("cannot find 'ClaudeAccountRegistry'")

- [ ] **Step 3: Implementazione**

```swift
// App/Sources/VedettaKit/ClaudeAccount.swift
import Foundation

/// One Claude Code account = one config dir (CLAUDE_CONFIG_DIR). The
/// default ~/.claude is always present and not removable; extra accounts
/// are user-registered. `path` (canonical) is the stable identity.
public struct ClaudeAccount: Equatable, Sendable, Identifiable {
    public let path: String
    public var alias: String?
    public var email: String?
    public var subscriptionType: String?
    public let isDefault: Bool
    public let isAvailable: Bool

    public init(
        path: String, alias: String?, email: String?,
        subscriptionType: String?, isDefault: Bool, isAvailable: Bool
    ) {
        self.path = path
        self.alias = alias
        self.email = email
        self.subscriptionType = subscriptionType
        self.isDefault = isDefault
        self.isAvailable = isAvailable
    }

    public var id: String { path }
    public var settingsPath: String { path + "/settings.json" }

    /// Alias if set, else email, else the directory name.
    public var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        if let email, !email.isEmpty { return email }
        return (path as NSString).lastPathComponent
    }
}

/// The persisted record (UserDefaults JSON) behind a registered account.
public struct StoredClaudeAccount: Codable, Equatable, Sendable {
    public var path: String
    public var alias: String?
    public var email: String?
    public var subscriptionType: String?

    public init(
        path: String, alias: String? = nil,
        email: String? = nil, subscriptionType: String? = nil
    ) {
        self.path = path
        self.alias = alias
        self.email = email
        self.subscriptionType = subscriptionType
    }
}

public enum ClaudeAccountRegistry {
    public static func resolve(
        defaultPath: String,
        stored: [StoredClaudeAccount],
        directoryExists: (String) -> Bool
    ) -> [ClaudeAccount] {
        let canonicalDefault = canonical(defaultPath)
        var seen: Set<String> = [canonicalDefault]
        var accounts = [ClaudeAccount(
            path: canonicalDefault, alias: nil, email: nil,
            subscriptionType: nil, isDefault: true,
            isAvailable: directoryExists(canonicalDefault)
        )]
        for record in stored {
            let path = canonical(record.path)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            accounts.append(ClaudeAccount(
                path: path, alias: record.alias, email: record.email,
                subscriptionType: record.subscriptionType, isDefault: false,
                isAvailable: directoryExists(path)
            ))
        }
        return accounts
    }

    public static func canonical(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
```

- [ ] **Step 4: `make test` → PASS**

- [ ] **Step 5: Commit**

```bash
git add App/Sources/VedettaKit/ClaudeAccount.swift App/Tests/VedettaKitTests/ClaudeAccountTests.swift
git commit -m "feat: ClaudeAccount and registry — one config dir per account"
```

---

### Task 2: AccountDigest + ClaudeCredentialLocator + ClaudeCredentials (VedettaKit)

**Files:**
- Create: `App/Sources/VedettaKit/ClaudeCredentialLocator.swift`
- Test: `App/Tests/VedettaKitTests/ClaudeCredentialLocatorTests.swift`

**Interfaces:**
- Consumes: niente.
- Produces: `AccountDigest.hash8(_ path: String) -> String` (sha256 su NFC, primi 8 hex); `ClaudeCredentialLocator.candidates(configDir:isDefault:) -> [Candidate]` con `enum Candidate: Equatable { case keychainService(String), credentialsFile(String) }`; `ClaudeCredentials.parse(_ data: Data) -> ClaudeCredentials?` con `{ accessToken, expiresAt: Date? }` e `isExpired(now:)`.

- [ ] **Step 1: Test che fallisce**

```swift
import Foundation
import Testing
@testable import VedettaKit

struct ClaudeCredentialLocatorTests {
    @Test func hash8IsDeterministicHex() {
        let a = AccountDigest.hash8("/Users/x/.claude-work")
        #expect(a.count == 8)
        #expect(a.allSatisfy(\.isHexDigit))
        #expect(a == AccountDigest.hash8("/Users/x/.claude-work"))
        #expect(a != AccountDigest.hash8("/Users/x/.claude-other"))
    }

    @Test func hash8NormalizesUnicodeNFC() {
        // "é" composto (U+00E9) vs "e"+combining acute (U+0065 U+0301):
        // stesso path logico, stesso hash.
        #expect(AccountDigest.hash8("/Users/x/caf\u{00E9}")
            == AccountDigest.hash8("/Users/x/cafe\u{0301}"))
    }

    @Test func defaultAccountUsesLegacyServiceThenFile() {
        let candidates = ClaudeCredentialLocator.candidates(
            configDir: "/Users/x/.claude", isDefault: true
        )
        #expect(candidates == [
            .keychainService("Claude Code-credentials"),
            .credentialsFile("/Users/x/.claude/.credentials.json"),
        ])
    }

    @Test func customAccountUsesNamespacedServiceFirst() {
        let hash = AccountDigest.hash8("/Users/x/.claude-work")
        let candidates = ClaudeCredentialLocator.candidates(
            configDir: "/Users/x/.claude-work", isDefault: false
        )
        #expect(candidates == [
            .keychainService("Claude Code-credentials-\(hash)"),
            .keychainService("Claude Code-credentials"),   // fallback CLI vecchie
            .credentialsFile("/Users/x/.claude-work/.credentials.json"),
        ])
    }

    @Test func parsesCredentialsJSON() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r","expiresAt":1753350000000,"scopes":["user:inference"]}}
        """
        let creds = try #require(ClaudeCredentials.parse(Data(json.utf8)))
        #expect(creds.accessToken == "tok-123")
        // expiresAt è in millisecondi epoch.
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_753_350_000))
        #expect(creds.isExpired(now: Date(timeIntervalSince1970: 1_753_360_000)))
        #expect(!creds.isExpired(now: Date(timeIntervalSince1970: 1_753_340_000)))
    }

    @Test func parseRejectsGarbage() {
        #expect(ClaudeCredentials.parse(Data("nope".utf8)) == nil)
        #expect(ClaudeCredentials.parse(Data("{}".utf8)) == nil)
    }
}
```

- [ ] **Step 2: `make test` → FAIL**

- [ ] **Step 3: Implementazione**

```swift
// App/Sources/VedettaKit/ClaudeCredentialLocator.swift
import CryptoKit
import Foundation

/// Claude Code namespaces its macOS Keychain item per config dir:
/// `Claude Code-credentials-<sha256(NFC(path)).hex[:8]>` (observed on
/// 2.1.218, undocumented — hence the fallback candidates).
public enum AccountDigest {
    public static func hash8(_ path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
    }
}

/// Where an account's OAuth credentials may live, in probe order.
public enum ClaudeCredentialLocator {
    public enum Candidate: Equatable, Sendable {
        case keychainService(String)
        case credentialsFile(String)
    }

    public static let legacyService = "Claude Code-credentials"

    public static func candidates(configDir: String, isDefault: Bool) -> [Candidate] {
        if isDefault {
            return [
                .keychainService(legacyService),
                .credentialsFile(configDir + "/.credentials.json"),
            ]
        }
        return [
            .keychainService("\(legacyService)-\(AccountDigest.hash8(configDir))"),
            .keychainService(legacyService),
            .credentialsFile(configDir + "/.credentials.json"),
        ]
    }
}

/// The credential blob Claude Code stores (Keychain item value or
/// .credentials.json content). Only what the usage probe needs.
public struct ClaudeCredentials: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date?

    public static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        var expiresAt: Date?
        if let millis = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            expiresAt = Date(timeIntervalSince1970: millis / 1000)
        }
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt)
    }

    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }
}
```

- [ ] **Step 4: `make test` → PASS**

- [ ] **Step 5: Commit**

```bash
git add App/Sources/VedettaKit/ClaudeCredentialLocator.swift App/Tests/VedettaKitTests/ClaudeCredentialLocatorTests.swift
git commit -m "feat: credential locator — keychain namespacing, fallbacks, token parse"
```

---

### Task 3: RateLimitHarvest — parser condiviso in VedettaKit

**Files:**
- Create: `App/Sources/VedettaKit/RateLimitHarvest.swift`
- Test: `App/Tests/VedettaKitTests/RateLimitHarvestTests.swift`
- Modify: `App/Sources/Vedetta/UsageModel.swift` (sostituisce `collectWindows`)

**Interfaces:**
- Produces: `QuotaWindow { percent: Int, resetsAt: Date?, windowMinutes: Int? }` (`Equatable`, `Sendable`); `RateLimitHarvest.windows(from data: Data) -> (fiveHour: QuotaWindow?, sevenDay: QuotaWindow?)` — stesso matching tollerante di oggi (`used_percentage|utilization|used_percent`, chiavi `5h|five_hour|primary` / `7d|seven_day|secondary`, `resets_at` ISO8601 o epoch). Funziona sia per il file della statusline sia per la risposta di `oauth/usage`.

- [ ] **Step 1: Test che fallisce**

```swift
import Foundation
import Testing
@testable import VedettaKit

struct RateLimitHarvestTests {
    @Test func parsesStatuslineShape() throws {
        let json = """
        {"five_hour":{"used_percentage":42,"resets_at":"2026-07-24T15:00:00Z"},
         "seven_day":{"used_percentage":81,"resets_at":"2026-07-28T00:00:00Z"}}
        """
        let result = RateLimitHarvest.windows(from: Data(json.utf8))
        #expect(result.fiveHour?.percent == 42)
        #expect(result.sevenDay?.percent == 81)
        #expect(result.fiveHour?.resetsAt != nil)
    }

    @Test func parsesOAuthUsageShape() {
        let json = """
        {"five_hour":{"utilization":12,"resets_at":"2026-07-24T15:00:00Z"},
         "seven_day":{"utilization":63,"resets_at":"2026-07-28T00:00:00Z"},
         "seven_day_opus":{"utilization":5,"resets_at":"2026-07-28T00:00:00Z"}}
        """
        let result = RateLimitHarvest.windows(from: Data(json.utf8))
        #expect(result.fiveHour?.percent == 12)
        #expect(result.sevenDay?.percent == 63)
    }

    @Test func parsesEpochResetAndNestedKeys() {
        let json = """
        {"rate_limits":{"primary":{"used_percent":9,"resets_at":1753350000}}}
        """
        let result = RateLimitHarvest.windows(from: Data(json.utf8))
        #expect(result.fiveHour?.percent == 9)
        #expect(result.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_753_350_000))
        #expect(result.sevenDay == nil)
    }

    @Test func garbageYieldsNothing() {
        let result = RateLimitHarvest.windows(from: Data("not json".utf8))
        #expect(result.fiveHour == nil && result.sevenDay == nil)
    }
}
```

- [ ] **Step 2: `make test` → FAIL**

- [ ] **Step 3: Implementazione** — trasloco fedele di `collectWindows` (la logica è quella già in produzione):

```swift
// App/Sources/VedettaKit/RateLimitHarvest.swift
import Foundation

public struct QuotaWindow: Equatable, Sendable {
    public var percent: Int
    public var resetsAt: Date?
    public var windowMinutes: Int?

    public init(percent: Int, resetsAt: Date? = nil, windowMinutes: Int? = nil) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }
}

/// Tolerant rate-limit parser shared by the statusline cache files and the
/// oauth/usage response: finds window objects carrying a utilization
/// percentage and a reset timestamp wherever the provider puts them.
public enum RateLimitHarvest {
    public static func windows(from data: Data) -> (fiveHour: QuotaWindow?, sevenDay: QuotaWindow?) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return (nil, nil) }
        var found: [(key: String, window: QuotaWindow)] = []
        collect(from: root, keyPath: "", into: &found)
        let fiveHour = found.first {
            $0.key.contains("5h") || $0.key.contains("five_hour") || $0.key.contains("primary")
        }?.window
        let sevenDay = found.first {
            $0.key.contains("7d") || $0.key.contains("seven_day") || $0.key.contains("secondary")
        }?.window
        return (fiveHour, sevenDay)
    }

    private static func collect(
        from object: [String: Any],
        keyPath: String,
        into result: inout [(key: String, window: QuotaWindow)]
    ) {
        let percent = (object["used_percentage"] as? NSNumber)?.intValue
            ?? (object["utilization"] as? NSNumber)?.intValue
            ?? (object["used_percent"] as? NSNumber)?.intValue
        if let percent {
            var resetsAt: Date?
            if let reset = object["resets_at"] as? String {
                resetsAt = ISO8601DateFormatter().date(from: reset)
            } else if let epoch = object["resets_at"] as? NSNumber {
                resetsAt = Date(timeIntervalSince1970: epoch.doubleValue)
            }
            result.append((keyPath.lowercased(), QuotaWindow(percent: percent, resetsAt: resetsAt)))
        }
        for (key, value) in object {
            if let nested = value as? [String: Any] {
                collect(from: nested, keyPath: keyPath + "/" + key, into: &result)
            }
        }
    }
}
```

In `UsageModel.swift`: dentro `refresh()` sostituisci il blocco `var windows … collectWindows … sevenDay =` con:

```swift
        let parsed = RateLimitHarvest.windows(from: Data(referencing: NSData(data: data)))
        fiveHour = parsed.fiveHour.map {
            Window(percent: $0.percent, resetsAt: $0.resetsAt, windowMinutes: $0.windowMinutes)
        }
        sevenDay = parsed.sevenDay.map {
            Window(percent: $0.percent, resetsAt: $0.resetsAt, windowMinutes: $0.windowMinutes)
        }
```

(dove `data` è il `Data` già letto; l'inizializzatore semplice `RateLimitHarvest.windows(from: data)` va benissimo — la riga sopra è equivalente) e **rimuovi** `collectWindows`. Aggiungi `import VedettaKit` se manca (c'è già per `SessionState`? verificare in testa al file — `UsageModel` oggi non lo importa: aggiungerlo).

- [ ] **Step 4: `make test && make app` → PASS**

- [ ] **Step 5: Commit**

```bash
git add App/Sources/VedettaKit/RateLimitHarvest.swift App/Tests/VedettaKitTests/RateLimitHarvestTests.swift App/Sources/Vedetta/UsageModel.swift
git commit -m "refactor: shared tolerant rate-limit parser in VedettaKit"
```

---

### Task 4: VedettaSetup per-account + fix removalKey

**Files:**
- Modify: `App/Sources/Vedetta/VedettaSetup.swift`

**Interfaces:**
- Consumes: `ClaudeAccount`/`StoredClaudeAccount`/`ClaudeAccountRegistry` (Task 1), `AccountDigest` (Task 2).
- Produces: `VedettaSetup.claudeAccounts: [ClaudeAccount]`; `registerClaudeAccount(_ path: String) -> ClaudeAccount`; `updateStoredClaudeAccount(path:mutate:)`; `removeClaudeAccount(path:)`; `statusLineCachePath(for:)`, `statusLinePath(for:)`; overload `claudeHooksInstalled(at:)`, `installClaudeHooks(at:)`, `healClaudeHooks()` (loop su tutti), `removeClaudeHooks(at:)`, `claudeStatusLineOwner(at:)`, `claimStatusLine(at:)`; `Notification.Name.vedettaClaudeAccountsChanged`. Fix `removalKey(for:)`.

- [ ] **Step 1: Fix del bug removalKey**

Riga 339, sostituisci:

```swift
        codexHome.isDefault ? codexRemovalKey : "(codexRemovalKey).(codexHome.path)"
```

con:

```swift
        codexHome.isDefault ? codexRemovalKey : "\(codexRemovalKey).\(codexHome.path)"
```

- [ ] **Step 2: Registry account + persistenza**

Dopo `registerCodexHome`, aggiungi:

```swift
    // MARK: - Claude accounts (one CLAUDE_CONFIG_DIR each)

    private static let claudeAccountsKey = "claude.customAccounts"

    static var storedClaudeAccounts: [StoredClaudeAccount] {
        guard let data = UserDefaults.standard.data(forKey: claudeAccountsKey),
              let stored = try? JSONDecoder().decode([StoredClaudeAccount].self, from: data)
        else { return [] }
        return stored
    }

    static var claudeAccounts: [ClaudeAccount] {
        ClaudeAccountRegistry.resolve(
            defaultPath: home + "/.claude",
            stored: storedClaudeAccounts,
            directoryExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    private static func saveStoredClaudeAccounts(_ accounts: [StoredClaudeAccount]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: claudeAccountsKey)
        NotificationCenter.default.post(name: .vedettaClaudeAccountsChanged, object: nil)
    }

    @discardableResult
    static func registerClaudeAccount(_ path: String) -> ClaudeAccount {
        let canonical = ClaudeAccountRegistry.canonical(path)
        var stored = storedClaudeAccounts
        if canonical != ClaudeAccountRegistry.canonical(home + "/.claude"),
           !stored.contains(where: { ClaudeAccountRegistry.canonical($0.path) == canonical }) {
            stored.append(StoredClaudeAccount(path: canonical))
            saveStoredClaudeAccounts(stored)
        }
        return claudeAccounts.first { $0.path == canonical }
            ?? ClaudeAccount(path: canonical, alias: nil, email: nil,
                             subscriptionType: nil, isDefault: false, isAvailable: true)
    }

    static func updateStoredClaudeAccount(
        path: String, mutate: (inout StoredClaudeAccount) -> Void
    ) {
        let canonical = ClaudeAccountRegistry.canonical(path)
        var stored = storedClaudeAccounts
        guard let index = stored.firstIndex(
            where: { ClaudeAccountRegistry.canonical($0.path) == canonical }
        ) else { return }
        mutate(&stored[index])
        saveStoredClaudeAccounts(stored)
    }

    static func removeClaudeAccount(path: String) {
        let canonical = ClaudeAccountRegistry.canonical(path)
        saveStoredClaudeAccounts(storedClaudeAccounts.filter {
            ClaudeAccountRegistry.canonical($0.path) != canonical
        })
    }
```

e in fondo al file (o accanto alle altre Notification in NotchPanelController — sceglere un posto solo):

```swift
extension Notification.Name {
    /// Posted when the Claude account registry changes.
    static let vedettaClaudeAccountsChanged = Notification.Name("vedettaClaudeAccountsChanged")
}
```

- [ ] **Step 3: Statusline per-account**

Sostituisci `writeStatusLineScript` con la versione parametrizzata e aggiungi i path helper:

```swift
    /// The per-account statusline drop: rl.json for the default account
    /// (compatibility with existing installs), rl-<hash8>.json otherwise.
    static func statusLineCachePath(for account: ClaudeAccount) -> String {
        account.isDefault
            ? cacheDir + "/rl.json"
            : cacheDir + "/rl-\(AccountDigest.hash8(account.path)).json"
    }

    static func statusLinePath(for account: ClaudeAccount) -> String {
        account.isDefault
            ? statusLinePath
            : binDir + "/vedetta-statusline-\(AccountDigest.hash8(account.path))"
    }

    private static func writeStatusLineScript(for account: ClaudeAccount) throws {
        let cacheFile = statusLineCachePath(for: account)
            .replacingOccurrences(of: home, with: "$HOME")
        let script = """
        #!/bin/bash
        # Vedetta statusline (auto-generated): captures rate_limits for the
        # usage strip. Add your own status output below — this file is only
        # rewritten if you delete it.
        input=$(cat)
        _rl=$(printf '%s' "$input" | /usr/bin/jq -c '.rate_limits // empty' 2>/dev/null)
        [ -n "$_rl" ] && printf '%s\\n' "$_rl" > "\(cacheFile)"
        """
        let path = statusLinePath(for: account)
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }
```

In `ensureRuntimeLayout()`, sostituisci `try writeStatusLineScript()` con:

```swift
        for account in claudeAccounts {
            try writeStatusLineScript(for: account)
        }
```

- [ ] **Step 4: Hook/owner/claim per-account**

Ricalca esattamente il pattern dei gemelli Codex — le versioni senza parametro restano e delegano al default o al loop:

```swift
    private static var defaultClaudeAccount: ClaudeAccount {
        claudeAccounts[0]
    }

    private static func removalKey(for account: ClaudeAccount) -> String {
        account.isDefault ? claudeRemovalKey : "\(claudeRemovalKey).\(account.path)"
    }

    private static func settingsBackupName(for account: ClaudeAccount) -> String {
        account.isDefault
            ? "settings.json"
            : "settings-\(AccountDigest.hash8(account.path)).json"
    }

    static func claudeHooksInstalled(at account: ClaudeAccount) -> Bool {
        guard let settings = try? configStore.read(
            at: URL(fileURLWithPath: account.settingsPath)
        ) else { return false }
        return HookConfigurator.isInstalled(in: settings)
    }

    @discardableResult
    static func installClaudeHooks(at account: ClaudeAccount) throws -> Bool {
        try writeStatusLineScript(for: account)
        let result = try configStore.mutate(
            at: URL(fileURLWithPath: account.settingsPath),
            backupDirectory: URL(fileURLWithPath: backupsDir),
            backupName: settingsBackupName(for: account)
        ) { settings in
            let (merged, hooksChanged) = HookConfigurator.mergingHooks(into: settings)
            let (final, statusChanged) = HookConfigurator.installingStatusLine(
                into: merged,
                command: statusLinePath(for: account),
                canReplace: statusLineIsOrphan
            )
            return (final, hooksChanged || statusChanged)
        }
        UserDefaults.standard.set(false, forKey: removalKey(for: account))
        return result.changed
    }

    static func claudeStatusLineOwner(at account: ClaudeAccount) -> StatusLineOwner {
        guard let settings = try? configStore.read(
            at: URL(fileURLWithPath: account.settingsPath)
        ), let statusLine = settings["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String, !command.isEmpty
        else { return .none }
        return command.contains("vedetta") ? .vedetta : .foreign(command)
    }

    @discardableResult
    static func claimStatusLine(at account: ClaudeAccount) throws -> Bool {
        try ensureRuntimeLayout()
        return try configStore.mutate(
            at: URL(fileURLWithPath: account.settingsPath),
            backupDirectory: URL(fileURLWithPath: backupsDir),
            backupName: settingsBackupName(for: account)
        ) { settings in
            HookConfigurator.installingStatusLine(
                into: settings,
                command: statusLinePath(for: account),
                canReplace: { _ in true }
            )
        }.changed
    }

    @discardableResult
    static func removeClaudeHooks(at account: ClaudeAccount) throws -> Bool {
        defer { UserDefaults.standard.set(true, forKey: removalKey(for: account)) }
        guard FileManager.default.fileExists(atPath: account.settingsPath) else { return false }
        return try configStore.mutate(
            at: URL(fileURLWithPath: account.settingsPath),
            backupDirectory: URL(fileURLWithPath: backupsDir),
            backupName: settingsBackupName(for: account),
            transform: HookConfigurator.removingHooks
        ).changed
    }
```

Poi adegua le versioni esistenti (stesse firme pubbliche, nuova sostanza):

```swift
    static func claudeHooksInstalled() -> Bool {
        claudeHooksInstalled(at: defaultClaudeAccount)
    }

    @discardableResult
    static func healClaudeHooks() throws -> Bool {
        var changed = false
        for account in claudeAccounts where account.isAvailable {
            guard !UserDefaults.standard.bool(forKey: removalKey(for: account)),
                  let settings = try? configStore.read(
                    at: URL(fileURLWithPath: account.settingsPath)
                  ),
                  HookConfigurator.hasAnyHook(in: settings),
                  !HookConfigurator.isInstalled(in: settings) else { continue }
            changed = try installClaudeHooks(at: account) || changed
        }
        return changed
    }

    @discardableResult
    static func installClaudeHooks() throws -> Bool {
        var changed = false
        for account in claudeAccounts where account.isAvailable {
            changed = try installClaudeHooks(at: account) || changed
        }
        return changed
    }

    @discardableResult
    static func removeClaudeHooks() throws -> Bool {
        var changed = false
        for account in claudeAccounts where account.isAvailable {
            changed = try removeClaudeHooks(at: account) || changed
        }
        return changed
    }

    static func claudeStatusLineOwner() -> StatusLineOwner {
        claudeStatusLineOwner(at: defaultClaudeAccount)
    }

    @discardableResult
    static func claimStatusLine() throws -> Bool {
        try claimStatusLine(at: defaultClaudeAccount)
    }
```

`claudeSettingsPath` resta (usato dal launcher/self-cleanup) ma ora è un alias del default. Nota: il self-cleanup del launcher continua a pulire solo `~/.claude` — accettato per v1 (documentare nel commit).

- [ ] **Step 5: `make test && make app` → PASS** (nessun test nuovo: la logica pura è nei task 1–2; qui si verifica che nulla regredisca)

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Vedetta/VedettaSetup.swift
git commit -m "feat: per-account claude setup — hooks, statusline, owner, claim; fix codex removal key"
```

---

### Task 5: Tag account sulle sessioni (bridge → reducer → AgentSession)

**Files:**
- Modify: `App/Sources/VedettaBridge/main.swift` (envelope)
- Modify: `App/Sources/VedettaKit/AgentSession.swift` (campo nuovo)
- Modify: `App/Sources/VedettaKit/SessionEventReducer.swift` (apply)
- Test: `App/Tests/VedettaKitTests/SessionEventReducerTests.swift` (aggiunta)

**Interfaces:**
- Produces: envelope root `"configDir": String` (solo se `CLAUDE_CONFIG_DIR` è settata); `AgentSession.claudeConfigDir: String?` (path canonico; `nil` = account default).

- [ ] **Step 1: Test che fallisce** (in `SessionEventReducerTests.swift`, stile dei test esistenti — adattare la costruzione dell'envelope a come fanno gli altri test del file):

```swift
    @Test func tagsSessionWithClaudeConfigDir() {
        let store = SessionStore()
        var envelope = TestEnvelopes.claude(event: "SessionStart", sessionId: "s1")
        envelope["configDir"] = "/Users/x/foo/../.claude-work"
        SessionEventReducer.apply(envelope, to: store)
        #expect(store.sessions.first?.claudeConfigDir == "/Users/x/.claude-work")

        let plain = TestEnvelopes.claude(event: "SessionStart", sessionId: "s2")
        SessionEventReducer.apply(plain, to: store)
        #expect(store.sessions.first { $0.id == "s2" }?.claudeConfigDir == nil)
    }
```

(Se il file non ha un helper `TestEnvelopes`, costruire il dizionario envelope come fanno i test vicini — leggerli prima.)

- [ ] **Step 2: `make test` → FAIL**

- [ ] **Step 3: Implementazione**

`AgentSession.swift`: accanto a `permissionMode` aggiungi campo + parametro di init con default:

```swift
    /// CLAUDE_CONFIG_DIR of the session's account (canonical); nil = default.
    public var claudeConfigDir: String?
```

`SessionEventReducer.apply`: dopo il blocco terminal (riga ~93), quando aggiorna/crea la sessione:

```swift
        let configDir = (envelope["configDir"] as? String)
            .map { ($0 as NSString).standardizingPath }
```

e assegna `claudeConfigDir = configDir ?? existing?.claudeConfigDir` (mai cancellare un tag già noto con un evento senza env).

`VedettaBridge/main.swift`: l'envelope diventa `var` e prima della serializzazione:

```swift
var envelope: [String: Any] = [
    "v": 1,
    "source": argument(after: "--source") ?? "claude",
    "capturedAt": Date().timeIntervalSince1970,
    "terminal": terminalIdentity(),
    "event": payload,
]
if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
   !configDir.isEmpty {
    envelope["configDir"] = configDir
}
```

- [ ] **Step 4: `make test && make app` → PASS**

- [ ] **Step 5: Commit**

```bash
git add App/Sources/VedettaBridge/main.swift App/Sources/VedettaKit/AgentSession.swift App/Sources/VedettaKit/SessionEventReducer.swift App/Tests/VedettaKitTests/SessionEventReducerTests.swift
git commit -m "feat: sessions carry their CLAUDE_CONFIG_DIR account tag"
```

---

### Task 6: AccountQuota merge + UsagePollScheduler (VedettaKit)

**Files:**
- Create: `App/Sources/VedettaKit/AccountQuota.swift`
- Test: `App/Tests/VedettaKitTests/AccountQuotaTests.swift`

**Interfaces:**
- Produces: `AccountQuota.Sample { fiveHour, sevenDay: QuotaWindow?, at: Date, origin: Origin }` con `enum Origin { case push, pull }`; `AccountQuota.merge(push: Sample?, pull: Sample?) -> Sample?` (il più recente vince in blocco); `AccountQuota.isStale(_ sample: Sample?, now: Date, tolerance: TimeInterval = 600) -> Bool`; `UsagePollScheduler` (struct pura): `nextAllowed(accountIndex:) -> Date`, `shouldPoll(account:now:) -> Bool`, `recordSuccess(account:now:)`, `record429(account:retryAfter:now:)`, `recordFailure(account:now:)` — base 300 s + stagger 20 s × indice, backoff 600→1200→1800 s (cap), Retry-After rispettato se maggiore.

- [ ] **Step 1: Test che fallisce**

```swift
import Foundation
import Testing
@testable import VedettaKit

struct AccountQuotaTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func sample(_ origin: AccountQuota.Origin, at: Date) -> AccountQuota.Sample {
        AccountQuota.Sample(
            fiveHour: QuotaWindow(percent: 10), sevenDay: nil, at: at, origin: origin
        )
    }

    @Test func freshestSampleWins() {
        let push = sample(.push, at: t0)
        let pull = sample(.pull, at: t0.addingTimeInterval(60))
        #expect(AccountQuota.merge(push: push, pull: pull)?.origin == .pull)
        #expect(AccountQuota.merge(push: pull, pull: push)?.origin == .pull)
        #expect(AccountQuota.merge(push: push, pull: nil)?.origin == .push)
        #expect(AccountQuota.merge(push: nil, pull: nil) == nil)
    }

    @Test func staleness() {
        let fresh = sample(.push, at: t0)
        #expect(!AccountQuota.isStale(fresh, now: t0.addingTimeInterval(300)))
        #expect(AccountQuota.isStale(fresh, now: t0.addingTimeInterval(601)))
        #expect(AccountQuota.isStale(nil, now: t0))
    }

    @Test func schedulerStaggersAndBacksOff() {
        var scheduler = UsagePollScheduler()
        let a = "acc-a", b = "acc-b"
        // Primo giro: subito pollabile, con stagger per indice.
        #expect(scheduler.shouldPoll(account: a, index: 0, now: t0))
        #expect(!scheduler.shouldPoll(account: b, index: 1, now: t0))          // stagger 20s
        #expect(scheduler.shouldPoll(account: b, index: 1, now: t0.addingTimeInterval(21)))
        // Successo → prossimo poll a base 300s.
        scheduler.recordSuccess(account: a, now: t0)
        #expect(!scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(299)))
        #expect(scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(301)))
        // 429 senza Retry-After → 600, poi 1200, poi cap 1800.
        scheduler.record429(account: a, retryAfter: nil, now: t0)
        #expect(!scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(599)))
        scheduler.record429(account: a, retryAfter: nil, now: t0)
        #expect(!scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(1199)))
        scheduler.record429(account: a, retryAfter: nil, now: t0)
        scheduler.record429(account: a, retryAfter: nil, now: t0)
        #expect(scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(1801)))
        // Retry-After più lungo del backoff vince.
        scheduler.record429(account: a, retryAfter: 3600, now: t0)
        #expect(!scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(1801)))
        #expect(scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(3601)))
        // Un successo azzera il backoff.
        scheduler.recordSuccess(account: a, now: t0)
        scheduler.record429(account: a, retryAfter: nil, now: t0)
        #expect(scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(601)))
    }
}
```

- [ ] **Step 2: `make test` → FAIL**

- [ ] **Step 3: Implementazione**

```swift
// App/Sources/VedettaKit/AccountQuota.swift
import Foundation

/// Per-account quota sample and the push/pull merge policy: the freshest
/// sample wins wholesale; anything older than the tolerance is stale and
/// the UI must show its age, never a bare percentage.
public enum AccountQuota {
    public enum Origin: Equatable, Sendable { case push, pull }

    public struct Sample: Equatable, Sendable {
        public var fiveHour: QuotaWindow?
        public var sevenDay: QuotaWindow?
        public var at: Date
        public var origin: Origin

        public init(fiveHour: QuotaWindow?, sevenDay: QuotaWindow?, at: Date, origin: Origin) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
            self.at = at
            self.origin = origin
        }
    }

    public static func merge(push: Sample?, pull: Sample?) -> Sample? {
        switch (push, pull) {
        case (nil, nil): return nil
        case (let sample?, nil): return sample
        case (nil, let sample?): return sample
        case (let push?, let pull?): return push.at >= pull.at ? push : pull
        }
    }

    public static func isStale(
        _ sample: Sample?, now: Date, tolerance: TimeInterval = 600
    ) -> Bool {
        guard let sample else { return true }
        return now.timeIntervalSince(sample.at) > tolerance
    }
}

/// Pure poll scheduling for the opt-in oauth/usage probe: base interval,
/// per-account stagger, exponential backoff on 429 honoring Retry-After.
public struct UsagePollScheduler: Sendable {
    public static let baseInterval: TimeInterval = 300
    public static let stagger: TimeInterval = 20
    public static let backoffSteps: [TimeInterval] = [600, 1200, 1800]

    private var nextAllowedAt: [String: Date] = [:]
    private var backoffLevel: [String: Int] = [:]

    public init() {}

    public func shouldPoll(account: String, index: Int, now: Date) -> Bool {
        if let next = nextAllowedAt[account] { return now >= next }
        // Never polled: allow after the per-account stagger from "now zero".
        return index == 0 || now.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: Self.baseInterval)
            >= Double(index) * Self.stagger
    }

    public mutating func recordSuccess(account: String, now: Date) {
        backoffLevel[account] = 0
        nextAllowedAt[account] = now.addingTimeInterval(Self.baseInterval)
    }

    public mutating func record429(account: String, retryAfter: TimeInterval?, now: Date) {
        let level = min(backoffLevel[account] ?? 0, Self.backoffSteps.count - 1)
        backoffLevel[account] = level + 1
        let backoff = Self.backoffSteps[level]
        nextAllowedAt[account] = now.addingTimeInterval(max(backoff, retryAfter ?? 0))
    }

    public mutating func recordFailure(account: String, now: Date) {
        nextAllowedAt[account] = now.addingTimeInterval(Self.baseInterval)
    }
}
```

Nota per l'implementatore: se il test dello stagger risulta fragile con questa formula, semplificare la semantica (es. primo poll consentito a `now ≥ epochStart + index*stagger` registrando `epochStart` al primo `shouldPoll`) e adeguare il test — l'intento fissato è: mai tutti gli account nello stesso istante, base 300 s, backoff 600/1200/1800 con Retry-After dominante, reset su successo.

- [ ] **Step 4: `make test` → PASS**

- [ ] **Step 5: Commit**

```bash
git add App/Sources/VedettaKit/AccountQuota.swift App/Tests/VedettaKitTests/AccountQuotaTests.swift
git commit -m "feat: per-account quota merge and polling scheduler with backoff"
```

---

### Task 7: UsageModel per-account + OAuthUsageProbe (opt-in)

**Files:**
- Create: `App/Sources/Vedetta/OAuthUsageProbe.swift`
- Modify: `App/Sources/Vedetta/UsageModel.swift`
- Modify: `App/Sources/Vedetta/Settings/SettingsDefaults.swift` (chiavi nuove)

**Interfaces:**
- Consumes: Task 1–6.
- Produces: `SettingsKey.claudeNetworkRefresh` (Bool, default false), `SettingsKey.claudeNetworkInterval` (Int secondi, default 300 — usato come override della base del scheduler); `UsageModel.claudeUsages: [ClaudeAccountUsage]` con `ClaudeAccountUsage { account: ClaudeAccount, sample: AccountQuota.Sample?, isStale: Bool }`; `UsageModel.activeClaudeAccountPath: String?` (settato dalla UI); `windows(for: .claude)` = finestre dell'account attivo (fallback: default, poi primo con dati); `OAuthUsageProbe.fetch(account:) async -> OAuthUsageProbe.Result` con `enum Result { case success(AccountQuota.Sample), rateLimited(retryAfter: TimeInterval?), unavailable }`.

- [ ] **Step 1: Chiavi settings**

In `SettingsDefaults.swift` (enum `SettingsKey`, seguire lo stile delle chiavi esistenti):

```swift
    static let claudeNetworkRefresh = "claudeNetworkRefresh"
    static let claudeNetworkInterval = "claudeNetworkInterval"
```

(e il default `false`/`300` dove il file registra i default, se lo fa — leggere il file prima.)

- [ ] **Step 2: OAuthUsageProbe**

```swift
// App/Sources/Vedetta/OAuthUsageProbe.swift
import Foundation
import VedettaKit

/// Opt-in quota probe: reads the account's OAuth access token from the
/// Claude Code Keychain item (or .credentials.json) and asks the same
/// endpoint /usage uses. Read-only: never refreshes tokens — an expired
/// token just means the account shows as stale until one of its sessions
/// runs. Undocumented endpoint; the User-Agent must look like the CLI or
/// the request lands in a throttled bucket.
enum OAuthUsageProbe {
    enum Result {
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

    static func fetch(account: ClaudeAccount) async -> Result {
        guard let credentials = readCredentials(for: account) else { return .unavailable }
        guard !credentials.isExpired(now: Date()) else { return .unavailable }
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
        // `security -w` may print hex for binary values; the item is JSON
        // text, but handle the hex form too.
        if text.hasPrefix("{") { return Data(text.utf8) }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex, let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) {
            guard let byte = UInt8(text[index..<next], radix: 16) else { return Data(text.utf8) }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
```

- [ ] **Step 3: UsageModel per-account**

Modifiche a `UsageModel.swift` (aggiungere `import VedettaKit` se non già dal Task 3):

1. Tipi e stato nuovi accanto alle @Published esistenti:

```swift
    struct ClaudeAccountUsage: Identifiable {
        let account: ClaudeAccount
        var sample: AccountQuota.Sample?
        var isStale: Bool
        var id: String { account.id }

        var fiveHour: Window? { sample?.fiveHour.map(Window.init(quota:)) }
        var sevenDay: Window? { sample?.sevenDay.map(Window.init(quota:)) }
    }

    @Published private(set) var claudeUsages: [ClaudeAccountUsage] = []
    /// Account whose windows the strip shows (set by the UI from the live
    /// sessions' tags); nil = default account.
    @Published var activeClaudeAccountPath: String?

    private var pullSamples: [String: AccountQuota.Sample] = [:]
    private var pollScheduler = UsagePollScheduler()
```

e l'adattatore:

```swift
extension UsageModel.Window {
    init(quota: QuotaWindow) {
        self.init(
            percent: quota.percent, resetsAt: quota.resetsAt,
            windowMinutes: quota.windowMinutes
        )
    }
}
```

2. `fiveHour`/`sevenDay` da @Published a **computed** (l'account attivo con fallback):

```swift
    private var activeClaudeUsage: ClaudeAccountUsage? {
        if let path = activeClaudeAccountPath,
           let match = claudeUsages.first(where: { $0.id == path }) {
            return match
        }
        return claudeUsages.first { $0.account.isDefault && $0.sample != nil }
            ?? claudeUsages.first { $0.sample != nil }
    }

    var fiveHour: Window? { activeClaudeUsage?.fiveHour }
    var sevenDay: Window? { activeClaudeUsage?.sevenDay }
```

(rimuovere le vecchie stored `@Published private(set) var fiveHour/sevenDay` e ogni assegnazione; `availableProviders`/`windows(for:)` continuano a compilare invariati).

3. `refresh()` — la parte Claude diventa per-account:

```swift
    func refresh(forceCodex: Bool = false) {
        if forceCodex { lastCodexProbe = nil }
        let fm = FileManager.default
        let now = Date()
        let accounts = VedettaSetup.claudeAccounts
        claudeUsages = accounts.map { account in
            let path = VedettaSetup.statusLineCachePath(for: account)
            var push: AccountQuota.Sample?
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let modified = attrs[.modificationDate] as? Date,
               let data = fm.contents(atPath: path) {
                let parsed = RateLimitHarvest.windows(from: data)
                if parsed.fiveHour != nil || parsed.sevenDay != nil {
                    push = AccountQuota.Sample(
                        fiveHour: parsed.fiveHour, sevenDay: parsed.sevenDay,
                        at: modified, origin: .push
                    )
                }
            }
            let merged = AccountQuota.merge(push: push, pull: pullSamples[account.id])
            return ClaudeAccountUsage(
                account: account, sample: merged,
                isStale: AccountQuota.isStale(merged, now: now)
            )
        }
        refreshPull(accounts: accounts, now: now)
        Task { await refreshCodex() }
    }

    /// The opt-in network probe: one account at a time as the scheduler
    /// allows, honoring backoff. No-op with the toggle off (zero network).
    private func refreshPull(accounts: [ClaudeAccount], now: Date) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.claudeNetworkRefresh) else { return }
        for (index, account) in accounts.enumerated()
        where pollScheduler.shouldPoll(account: account.id, index: index, now: now) {
            pollScheduler.recordFailure(account: account.id, now: now)  // provisional: prevents re-entry
            Task { [weak self] in
                let result = await OAuthUsageProbe.fetch(account: account)
                await MainActor.run {
                    guard let self else { return }
                    switch result {
                    case .success(let sample):
                        self.pullSamples[account.id] = sample
                        self.pollScheduler.recordSuccess(account: account.id, now: Date())
                        self.refresh()
                    case .rateLimited(let retryAfter):
                        self.pollScheduler.record429(
                            account: account.id, retryAfter: retryAfter, now: Date()
                        )
                    case .unavailable:
                        self.pollScheduler.recordFailure(account: account.id, now: Date())
                    }
                }
            }
        }
    }
```

Attenzione ricorsione: `refresh()` dentro `.success` richiama `refreshPull`, ma lo scheduler ha già `nextAllowedAt` nel futuro per quell'account → nessun loop. Verificarlo a mano ragionando sul flusso prima di committare.

- [ ] **Step 4: `make test && make app` → PASS**

- [ ] **Step 5: Verifica manuale rapida senza rete**

Run: `open dist/Vedetta.app`, poi `echo '{"cmd":"usage"}' | nc -U ~/.vedetta/run/vedetta.sock`
Expected: la strip funziona come prima (account default via rl.json); **nessuna connessione di rete** (toggle off — controllare con `nettop -p Vedetta -l 1` che non compaia traffico verso api.anthropic.com).

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Vedetta/OAuthUsageProbe.swift App/Sources/Vedetta/UsageModel.swift App/Sources/Vedetta/Settings/SettingsDefaults.swift
git commit -m "feat: per-account usage model with opt-in oauth quota probe"
```

---

### Task 8: Drill-down nel notch espanso

**Files:**
- Create: `App/Sources/Vedetta/UI/UsageDrilldownView.swift`
- Modify: `App/Sources/Vedetta/NotchPanelController.swift` (`NotchUIModel` + reset)
- Modify: `App/Sources/Vedetta/UI/NotchView.swift` (tap strip + ramo contenuto)

**Interfaces:**
- Consumes: `UsageModel.claudeUsages`, `windows(for: .codex)`, `usageColor` (esistente in NotchView — spostare la funzione in un helper condiviso o duplicarla nella nuova view), `AgentSession.claudeConfigDir` (Task 5), `VedettaSetup.claudeAccounts`.
- Produces: `NotchUIModel.usageDrilldown: Bool`; vista drill-down con righe account cliccabili (copy comando login).

- [ ] **Step 1: NotchUIModel + reset**

In `NotchUIModel` (NotchPanelController.swift, ~riga 657):

```swift
    /// The expanded panel shows the provider→accounts usage view instead
    /// of the session list; entered by tapping the usage strip, reset on
    /// collapse like showAllSessions.
    @Published var usageDrilldown = false
```

In `setExpanded(_:)`, nel ramo `if !expanded` accanto a `uiModel.showAllSessions = false`:

```swift
            uiModel.usageDrilldown = false
```

(NON in `focusInterrupt()`: un interrupt prevale visivamente perché `expandedContent` dà priorità al focusedSession, ma alla chiusura dell'interrupt si torna alla vista usage se era aperta — comportamento accettato.)

- [ ] **Step 2: NotchView — tap e ramo**

In `usageSummary`, sostituisci `.onTapGesture { usage.cycleProvider() }` con:

```swift
        .onTapGesture { model.usageDrilldown.toggle() }
```

In `expandedContent`, il blocco condizionale diventa:

```swift
            if let session = focusedSession {
                peekContent(session)
            } else if model.usageDrilldown {
                UsageDrilldownView(usage: usage, store: store)
            } else {
                sessionList
            }
        }
```

- [ ] **Step 3: La vista**

```swift
// App/Sources/Vedetta/UI/UsageDrilldownView.swift
import AppKit
import SwiftUI
import VedettaKit

/// Provider → accounts quota view, swapped in for the session list when
/// the user taps the usage strip. Every Claude account gets a row with
/// its 5h/7d windows; stale data shows its age, never a bare percentage.
struct UsageDrilldownView: View {
    @ObservedObject var usage: UsageModel
    @ObservedObject var store: SessionStore
    @State private var copiedAccountId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("CLAUDE")
            ForEach(usage.claudeUsages) { entry in
                accountRow(entry)
            }
            let codexWindows = usage.windows(for: .codex)
            if !codexWindows.isEmpty {
                sectionHeader("CODEX")
                HStack(spacing: 10) {
                    ForEach(Array(codexWindows.enumerated()), id: \.offset) { _, entry in
                        windowCell(label: entry.label, window: entry.window)
                    }
                    Spacer()
                }
                .padding(.leading, 10)
            }
        }
        .padding(.top, 2)
    }

    /// The account whose sessions were active most recently (nil tag =
    /// the default account).
    private var activeAccountPath: String? {
        let defaultPath = VedettaSetup.claudeAccounts.first?.path
        return store.sessions
            .filter { $0.agent == .claude && $0.state != .completed }
            .max { $0.lastActivityAt < $1.lastActivityAt }
            .map { $0.claudeConfigDir ?? defaultPath ?? "" }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .kerning(2)
            .foregroundStyle(Theme.secondaryText)
    }

    private func accountRow(_ entry: UsageModel.ClaudeAccountUsage) -> some View {
        let isActive = entry.account.path == activeAccountPath
        return HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Theme.color(for: .waitingForInput) : .clear)
                .frame(width: 5, height: 5)
            Text(entry.account.displayName)
                .font(.system(size: 11.5, weight: isActive ? .bold : .regular))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            if copiedAccountId == entry.id {
                Text("command copied")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.color(for: .waitingForInput))
            } else if let sample = entry.sample {
                if entry.isStale {
                    Text("stale \(age(of: sample.at))")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText.opacity(0.7))
                } else {
                    if let fiveHour = entry.fiveHour {
                        windowCell(label: "5h", window: fiveHour)
                    }
                    if let sevenDay = entry.sevenDay {
                        windowCell(label: "7d", window: sevenDay)
                    }
                }
            } else {
                Text("no data")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText.opacity(0.5))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { copyLoginCommand(entry.account) }
    }

    private func windowCell(label: String, window: UsageModel.Window) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(Theme.secondaryText)
            Text("\(window.percent)%")
                .bold()
                .foregroundStyle(usageColor(window.percent))
            if let reset = window.resetLabel {
                Text(reset).foregroundStyle(Theme.secondaryText.opacity(0.7))
            }
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func usageColor(_ percent: Int) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return Theme.color(for: .waitingForInput)
    }

    private func age(of date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds >= 3600 { return "\(seconds / 3600)h" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    /// The nice-to-have: hand the user a ready login/switch command. No
    /// terminal is raised and no focus moves — it lands in the clipboard.
    private func copyLoginCommand(_ account: ClaudeAccount) {
        let command = account.isDefault
            ? "claude"
            : "CLAUDE_CONFIG_DIR=\(account.path) claude"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedAccountId = account.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copiedAccountId == account.id { copiedAccountId = nil }
        }
    }
}
```

Nota: `usageColor` in NotchView usa soglie 50/80 — mantenere identiche (verificare a riga ~495 e allineare se differiscono).

- [ ] **Step 4: Sincronizza l'account attivo per la strip**

In `UsageDrilldownView` non serve; per la strip, in `NotchView` dove già osserva `store`, aggiungi un aggiornamento del modello (es. in `expandedContent` via `.onChange` o meglio nel punto in cui `usageSummary` legge): la via più semplice e senza cicli è calcolare in NotchView:

```swift
    /// Feed the usage model the account whose sessions are most recently
    /// active, so the strip shows the right account's windows.
    private func syncActiveAccount() {
        let defaultPath = VedettaSetup.claudeAccounts.first?.path
        let active = store.sessions
            .filter { $0.agent == .claude && $0.state != .completed }
            .max { $0.lastActivityAt < $1.lastActivityAt }
            .map { $0.claudeConfigDir ?? defaultPath ?? "" }
        if usage.activeClaudeAccountPath != active {
            usage.activeClaudeAccountPath = active
        }
    }
```

chiamata da `.onReceive(store.objectWillChange) { _ in syncActiveAccount() }` sul body (o `.onChange(of: store.sessions)` se `sessions` è Equatable — scegliere quella che compila senza loop).

- [ ] **Step 5: `make test && make app` → PASS**, poi `open dist/Vedetta.app`: tap sulla strip → drill-down con l'account default; tap di nuovo → card. Click sulla riga → "command copied" e comando negli appunti (`pbpaste`).

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Vedetta/UI/UsageDrilldownView.swift App/Sources/Vedetta/UI/NotchView.swift App/Sources/Vedetta/NotchPanelController.swift
git commit -m "feat: usage drill-down — provider to accounts view in the expanded notch"
```

---

### Task 9: Settings → Accounts, dump socket, verifica E2E

**Files:**
- Modify: `App/Sources/Vedetta/Settings/SettingsView.swift` (Page enum + pagina nuova)
- Modify: `App/Sources/Vedetta/EventDispatcher.swift` (dump usage per-account)
- Modify: `docs/vi-binary-audit.md` (progress log)

**Interfaces:**
- Consumes: tutto quanto sopra; `claude auth status --json` per l'identità.
- Produces: pagina Accounts; dump `{"cmd":"usage"}` con array `claudeAccounts`.

- [ ] **Step 1: Page enum**

In `SettingsView.swift` aggiungi il case `accounts` dopo `integrations` (title "Accounts", symbol `person.2.badge.key.fill`, tint `.orange`, e il ramo `case .accounts: AccountsSettingsPage()`).

- [ ] **Step 2: La pagina**

In fondo al file:

```swift
private struct AccountsSettingsPage: View {
    @State private var accounts = VedettaSetup.claudeAccounts
    @AppStorage(SettingsKey.claudeNetworkRefresh) private var networkRefresh = false

    var body: some View {
        SettingsSection(
            title: "Claude accounts",
            footer: "One account per config dir (CLAUDE_CONFIG_DIR). Hooks and the usage statusline install per account; sessions started with that dir show up in the notch tagged with it."
        ) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { RowDivider() }
                AccountRow(account: account, onChange: reload)
            }
            RowDivider()
            SettingsRow(
                title: "Add account…",
                subtitle: "Pick (or create) a config dir, e.g. ~/.claude-work. Log into it from your terminal — copy the command from the account row."
            ) {
                Button("Add…") { addAccount() }
            }
        }
        SettingsSection(
            title: "Network refresh",
            footer: "Reads each account's quota via Claude's own usage endpoint with the credentials already on this Mac. Read-only, undocumented endpoint, ~5 min cadence with backoff. Off = Vedetta stays fully offline."
        ) {
            SettingsRow(
                title: "Refresh quota over the network",
                subtitle: "Keeps idle accounts' usage fresh without an active session."
            ) {
                Toggle("", isOn: $networkRefresh)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .vedettaClaudeAccountsChanged
        )) { _ in reload() }
    }

    private func reload() {
        accounts = VedettaSetup.claudeAccounts
    }

    private func addAccount() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Use as account dir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let account = VedettaSetup.registerClaudeAccount(url.path)
        try? VedettaSetup.installClaudeHooks(at: account)
        reload()
    }
}

private struct AccountRow: View {
    let account: ClaudeAccount
    var onChange: () -> Void
    @State private var alias: String = ""
    @State private var hooksInstalled = false
    @State private var owner = VedettaSetup.StatusLineOwner.none
    @State private var identityError: String?

    private var subtitle: String {
        var parts: [String] = [account.path]
        if let email = account.email { parts.append(email) }
        if let plan = account.subscriptionType { parts.append(plan) }
        if case .foreign = owner { parts.append("foreign statusline") }
        if !hooksInstalled { parts.append("hooks not installed") }
        if let identityError { parts.append(identityError) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        SettingsRow(title: account.displayName, subtitle: subtitle) {
            HStack(spacing: 8) {
                if !account.isDefault {
                    TextField("Alias", text: $alias)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { saveAlias() }
                }
                Button("Identify") { refreshIdentity() }
                if !hooksInstalled {
                    Button("Hook") {
                        try? VedettaSetup.installClaudeHooks(at: account)
                        refreshState()
                    }
                }
                if case .foreign = owner {
                    Button("Claim statusline") {
                        try? VedettaSetup.claimStatusLine(at: account)
                        refreshState()
                    }
                }
                if !account.isDefault {
                    Button("Remove") {
                        VedettaSetup.removeClaudeAccount(path: account.path)
                        onChange()
                    }
                }
            }
        }
        .onAppear {
            alias = account.alias ?? ""
            refreshState()
        }
    }

    private func refreshState() {
        hooksInstalled = VedettaSetup.claudeHooksInstalled(at: account)
        owner = VedettaSetup.claudeStatusLineOwner(at: account)
    }

    private func saveAlias() {
        VedettaSetup.updateStoredClaudeAccount(path: account.path) {
            $0.alias = alias.isEmpty ? nil : alias
        }
        onChange()
    }

    /// `claude auth status --json` for this config dir: email + plan.
    private func refreshIdentity() {
        identityError = nil
        let path = account.path
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "claude auth status --json 2>/dev/null"]
            var environment = ProcessInfo.processInfo.environment
            environment["CLAUDE_CONFIG_DIR"] = path
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let object = try? JSONSerialization.jsonObject(with: data),
                      let root = object as? [String: Any] else {
                    identityError = "identity check failed"
                    return
                }
                let loggedIn = (root["loggedIn"] as? Bool) ?? false
                guard loggedIn else {
                    identityError = "not logged in"
                    return
                }
                let email = root["email"] as? String
                    ?? (root["account"] as? [String: Any])?["email"] as? String
                let plan = root["subscriptionType"] as? String
                    ?? (root["account"] as? [String: Any])?["subscriptionType"] as? String
                VedettaSetup.updateStoredClaudeAccount(path: path) {
                    $0.email = email
                    $0.subscriptionType = plan
                }
                onChange()
            }
        }
    }
}
```

(Adattare i nomi dei campi del JSON di `auth status` a quelli reali osservati in E2E — la ricerca dà `email`, `orgId`, `subscriptionType`; il codice sopra prova le due forme più probabili e va rifinito col dato vero alla prima esecuzione.)

- [ ] **Step 3: Dump socket per-account**

In `EventDispatcher.handleCommand`, nel ramo `"usage"`, aggiungi al dizionario di risposta:

```swift
            "claudeAccounts": UsageModel.shared.claudeUsages.map { entry in
                [
                    "path": entry.account.path,
                    "name": entry.account.displayName,
                    "fiveHour": entry.fiveHour?.percent ?? -1,
                    "sevenDay": entry.sevenDay?.percent ?? -1,
                    "stale": entry.isStale,
                    "origin": entry.sample?.origin == .pull ? "pull" : "push",
                ] as [String: Any]
            },
```

- [ ] **Step 4: `make test && make app` → PASS**

- [ ] **Step 5: Verifica E2E (con Matteo)**

1. Settings → Accounts: l'account default appare; Add… con `~/.claude-test`; Hook; copia comando dal drill-down; nel terminale: login del secondo account e sessione live → card nel notch, `{"cmd":"dump"}` mostra il tag configDir.
2. Drill-down: 2 account con barre reali; account senza dati → "no data"; con Vedetta spenta la notte → "stale Nh".
3. Opt-in: toggle ON → entro ~5 min le righe idle si popolano (verificare con `{"cmd":"usage"}`); toggle OFF → `nettop` pulito.
4. Click riga → comando corretto in `pbpaste`.
5. Conferma manuale di Matteo prima di dichiarare chiuso.

- [ ] **Step 6: Audit + commit**

Appendi al progress log di `docs/vi-binary-audit.md` l'entry "Pass 9 — multi-account usage" (fonti della ricerca, decisioni, esiti E2E), poi:

```bash
git add App/Sources/Vedetta/Settings/SettingsView.swift App/Sources/Vedetta/EventDispatcher.swift docs/vi-binary-audit.md docs/superpowers/plans/2026-07-24-multi-account-usage.md
git commit -m "feat: accounts settings page, per-account usage dump, e2e pass"
```
