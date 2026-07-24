import Foundation
import VedettaKit

/// Filesystem-facing setup: runtime directories, the launcher script in
/// `~/.vedetta/bin`, and hook install/removal for Claude Code and Codex
/// (always with a timestamped backup before an existing file changes).
enum VedettaSetup {
    private static let configStore = HookConfigFileStore()
    private static let claudeRemovalKey = "hooks.deliberatelyRemoved.claude"
    private static let codexRemovalKey = "hooks.deliberatelyRemoved.codex"
    private static let codexHomePathsKey = "codex.customHomes"
    static let home = NSHomeDirectory()
    static var rootDir: String { home + "/.vedetta" }
    static var binDir: String { rootDir + "/bin" }
    static var runDir: String { rootDir + "/run" }
    static var backupsDir: String { rootDir + "/backups" }
    static var socketPath: String { runDir + "/vedetta.sock" }
    static var launcherPath: String { binDir + "/vedetta-bridge" }
    static var orphanedPath: String { rootDir + "/.orphaned" }
    static var claudeSettingsPath: String { home + "/.claude/settings.json" }
    static var codexHooksPath: String { codexHomes[0].hooksPath }
    static var codexHomes: [CodexHome] {
        CodexHomeRegistry.resolve(
            defaultPath: home + "/.codex",
            customPaths: UserDefaults.standard.stringArray(forKey: codexHomePathsKey) ?? [],
            directoryExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    @discardableResult
    static func registerCodexHome(_ path: String) -> CodexHome {
        let canonical = CodexHomeRegistry.canonical(path)
        var paths = UserDefaults.standard.stringArray(forKey: codexHomePathsKey) ?? []
        if !paths.map(CodexHomeRegistry.canonical).contains(canonical),
           canonical != CodexHomeRegistry.canonical(home + "/.codex") {
            paths.append(canonical)
            UserDefaults.standard.set(paths, forKey: codexHomePathsKey)
        }
        return codexHomes.first(where: { $0.path == canonical })
            ?? CodexHome(path: canonical, isDefault: false, isAvailable: true)
    }

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

    /// Upserts the record for `path`: creates one if missing, so even the
    /// default account (not otherwise stored) can carry an alias/identity.
    static func updateStoredClaudeAccount(
        path: String, mutate: (inout StoredClaudeAccount) -> Void
    ) {
        let canonical = ClaudeAccountRegistry.canonical(path)
        var stored = storedClaudeAccounts
        if let index = stored.firstIndex(
            where: { ClaudeAccountRegistry.canonical($0.path) == canonical }
        ) {
            mutate(&stored[index])
        } else {
            var record = StoredClaudeAccount(path: canonical)
            mutate(&record)
            stored.append(record)
        }
        saveStoredClaudeAccounts(stored)
    }

    static func removeClaudeAccount(path: String) {
        let canonical = ClaudeAccountRegistry.canonical(path)
        saveStoredClaudeAccounts(storedClaudeAccounts.filter {
            ClaudeAccountRegistry.canonical($0.path) != canonical
        })
    }

    // MARK: - Runtime layout

    static var cacheDir: String { rootDir + "/cache" }
    static var statusLinePath: String { binDir + "/vedetta-statusline" }

    static func ensureRuntimeLayout() throws {
        let fm = FileManager.default
        for dir in [binDir, runDir, backupsDir, cacheDir, rootDir + "/custom-sounds"] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // The app is alive: reset the launcher's orphan clock so a past
        // absence never counts toward the self-cleanup grace period.
        try? fm.removeItem(atPath: orphanedPath)
        try writeLauncher()
        for account in claudeAccounts {
            try writeStatusLineScript(for: account)
        }
    }

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

    /// Harvests `rate_limits` from the statusline JSON into the account's
    /// cache file; prints nothing (empty statusline) and leaves room for
    /// user code.
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

    /// The launcher resolves the real helper inside the app bundle, so the
    /// hooks survive app updates and disappear gracefully with the app. If the
    /// app has been gone for over 5 minutes (mdfind can't find it either), the
    /// launcher cleans up after itself — hooks, statusLine and the companion
    /// extension — so an uninstalled Vedetta leaves no trace, like the original.
    private static func writeLauncher() throws {
        let bundlePath = Bundle.main.bundlePath
        let script = """
        #!/bin/zsh
        # vedetta-bridge launcher (auto-generated by Vedetta, do not edit)
        H=/Contents/Helpers/vedetta-bridge
        O="$HOME/.vedetta/.orphaned"
        C="$HOME/.vedetta/bin/.bridge-cache"
        for P in "\(bundlePath)" "/Applications/Vedetta.app" "$HOME/Applications/Vedetta.app"; do
          B="${P}${H}"
          if [ -x "$B" ]; then /bin/rm -f "$O"; exec "$B" "$@"; fi
        done
        if [ -f "$C" ]; then
          read -r P < "$C"; B="${P}${H}"
          if [ -x "$B" ]; then /bin/rm -f "$O"; exec "$B" "$@"; fi
        fi
        P="$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == 'app.vedetta.macos'" 2>/dev/null | /usr/bin/head -1)"
        B="${P}${H}"
        if [ -n "$P" ] && [ -x "$B" ]; then echo "$P" > "$C"; /bin/rm -f "$O"; exec "$B" "$@"; fi
        # ── app not found: self-cleanup after a 5-minute grace period ──
        if [ -f "$O" ]; then
          read -r T < "$O"
          if [ "$(( $(/bin/date +%s) - T ))" -ge 300 ]; then
            S="$(/bin/date -u +%Y-%m-%dT%H-%M-%SZ).$$"
            [ -f "$HOME/.claude/settings.json" ] && /bin/cp -p "$HOME/.claude/settings.json" "$HOME/.vedetta/backups/settings.json.$S"
            [ -f "$HOME/.codex/hooks.json" ] && /bin/cp -p "$HOME/.codex/hooks.json" "$HOME/.vedetta/backups/hooks.json.$S"
            /usr/bin/osascript -l JavaScript <<'JSEOF' 2>/dev/null
        ObjC.import('Foundation')
        var h=ObjC.unwrap($.NSHomeDirectory()),m='vedetta'
        function rd(p){var d=$.NSData.alloc.initWithContentsOfFile(p);if(!d||!d.length)return null;return ObjC.unwrap($.NSString.alloc.initWithDataEncoding(d,$.NSUTF8StringEncoding))}
        function wr(p,s){$.NSString.alloc.initWithUTF8String(s).writeToFileAtomicallyEncodingError(p,true,$.NSUTF8StringEncoding,null)}
        function clean(p){var s=rd(p);if(!s)return;var j;try{j=JSON.parse(s)}catch(e){return}var ch=false;if(j.hooks){for(var ev in j.hooks){var a=j.hooks[ev];if(!Array.isArray(a))continue;var f=a.filter(function(e){if(Array.isArray(e.hooks)){e.hooks=e.hooks.filter(function(x){return(x.command||'').indexOf(m)===-1});if(!e.hooks.length)return false}return(e.command||'').indexOf(m)===-1});if(f.length!==a.length)ch=true;if(!f.length)delete j.hooks[ev];else j.hooks[ev]=f}if(!Object.keys(j.hooks).length)delete j.hooks}if(j.statusLine&&(j.statusLine.command||'').indexOf(m)!==-1){delete j.statusLine;ch=true}if(ch)wr(p,JSON.stringify(j,null,2))}
        clean(h+'/.claude/settings.json')
        clean(h+'/.codex/hooks.json')
        JSEOF
            for cli in code code-insiders cursor windsurf; do
              command -v "$cli" >/dev/null 2>&1 && "$cli" --uninstall-extension vedetta.terminal-focus >/dev/null 2>&1 &
            done
            /bin/rm -f "$HOME/.vedetta/bin/vedetta-bridge" "$HOME/.vedetta/bin/vedetta-statusline" "$C" "$O"
          fi
        else
          /bin/date +%s > "$O"
        fi
        exit 0
        """
        try script.write(toFile: launcherPath, atomically: true, encoding: .utf8)
        chmod(launcherPath, 0o755)
    }

    // MARK: - Coding-agent hooks

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

    static func claudeHooksInstalled() -> Bool {
        claudeHooksInstalled(at: defaultClaudeAccount)
    }

    static func claudeHooksInstalled(at account: ClaudeAccount) -> Bool {
        guard let settings = try? configStore.read(
            at: URL(fileURLWithPath: account.settingsPath)
        ) else { return false }
        return HookConfigurator.isInstalled(in: settings)
    }

    static func codexHooksInstalled() -> Bool {
        let available = codexHomes.filter(\.isAvailable)
        return !available.isEmpty && available.allSatisfy(codexHooksInstalled(at:))
    }

    static func codexHooksInstalled(at codexHome: CodexHome) -> Bool {
        guard let settings = try? configStore.read(
            at: URL(fileURLWithPath: codexHome.hooksPath)
        ) else { return false }
        return HookConfigurator.codexHooksInstalled(in: settings)
    }

    static func codexHooksExplicitlyDisabled(at codexHome: CodexHome) -> Bool {
        guard let config = try? String(contentsOfFile: codexHome.configPath, encoding: .utf8) else {
            return false
        }
        return CodexFeatureConfig.hooksExplicitlyDisabled(in: config)
    }

    /// Self-heal on every launch: if we were installed but some events
    /// drifted (e.g. new hook events shipped in an update, or another app
    /// rewrote settings.json), re-merge the missing ones. Never installs
    /// from scratch — a settings.json with no vedetta hook is left as is,
    /// so a deliberate uninstall isn't undone.
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
    static func healCodexHooks() throws -> Bool {
        var changed = false
        for codexHome in codexHomes where codexHome.isAvailable {
            guard !codexHooksExplicitlyDisabled(at: codexHome),
                  !UserDefaults.standard.bool(forKey: removalKey(for: codexHome)),
                  let settings = try? configStore.read(
                    at: URL(fileURLWithPath: codexHome.hooksPath)
                  ),
                  HookConfigurator.hasAnyCodexHook(in: settings),
                  !HookConfigurator.codexHooksInstalled(in: settings) else { continue }
            changed = try installCodexHooks(at: codexHome) || changed
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

    @discardableResult
    static func installCodexHooks() throws -> Bool {
        var changed = false
        for codexHome in codexHomes where codexHome.isAvailable {
            changed = try installCodexHooks(at: codexHome) || changed
        }
        return changed
    }

    @discardableResult
    static func installCodexHooks(at codexHome: CodexHome) throws -> Bool {
        guard !codexHooksExplicitlyDisabled(at: codexHome) else { return false }
        let backupName = codexHome.isDefault
            ? "hooks-default.json"
            : "hooks-\((codexHome.path as NSString).lastPathComponent).json"
        let result = try configStore.mutate(
            at: URL(fileURLWithPath: codexHome.hooksPath),
            backupDirectory: URL(fileURLWithPath: backupsDir),
            backupName: backupName,
            transform: HookConfigurator.mergingCodexHooks
        )
        // Deliberately do not mutate ~/.codex/config.toml or synthesize
        // trusted_hash values. Codex owns that trust decision and asks the
        // user to review new hook commands on the next interactive launch.
        UserDefaults.standard.set(false, forKey: removalKey(for: codexHome))
        return result.changed
    }

    @discardableResult
    static func installAgentHooks() -> HookAgentOperationReport {
        HookAgentOperationReport.run(
            claude: installClaudeHooks,
            codex: installCodexHooks
        )
    }

    @discardableResult
    static func removeClaudeHooks() throws -> Bool {
        var changed = false
        for account in claudeAccounts where account.isAvailable {
            changed = try removeClaudeHooks(at: account) || changed
        }
        return changed
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

    @discardableResult
    static func removeCodexHooks() throws -> Bool {
        var changed = false
        for codexHome in codexHomes where codexHome.isAvailable {
            changed = try removeCodexHooks(at: codexHome) || changed
        }
        return changed
    }

    @discardableResult
    static func removeCodexHooks(at codexHome: CodexHome) throws -> Bool {
        defer { UserDefaults.standard.set(true, forKey: removalKey(for: codexHome)) }
        guard FileManager.default.fileExists(atPath: codexHome.hooksPath) else { return false }
        let backupName = codexHome.isDefault
            ? "hooks-default.json"
            : "hooks-\((codexHome.path as NSString).lastPathComponent).json"
        return try configStore.mutate(
            at: URL(fileURLWithPath: codexHome.hooksPath),
            backupDirectory: URL(fileURLWithPath: backupsDir),
            backupName: backupName,
            transform: HookConfigurator.removingCodexHooks
        ).changed
    }

    @discardableResult
    static func removeAgentHooks() -> HookAgentOperationReport {
        HookAgentOperationReport.run(
            claude: removeClaudeHooks,
            codex: removeCodexHooks
        )
    }

    /// Who owns the Claude statusLine slot (the harvest source for the
    /// Claude usage strip).
    enum StatusLineOwner: Equatable {
        case vedetta
        case foreign(String)
        case none
    }

    static func claudeStatusLineOwner() -> StatusLineOwner {
        claudeStatusLineOwner(at: defaultClaudeAccount)
    }

    static func claudeStatusLineOwner(at account: ClaudeAccount) -> StatusLineOwner {
        guard let settings = try? configStore.read(
            at: URL(fileURLWithPath: account.settingsPath)
        ), let statusLine = settings["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String, !command.isEmpty
        else { return .none }
        return command.contains("vedetta") ? .vedetta : .foreign(command)
    }

    /// Replaces whatever occupies the statusLine slot with Vedetta's
    /// harvester (timestamped backup first). Only ever called from an
    /// explicit user action in Settings — never automatically: a foreign
    /// statusLine may be the user's own.
    @discardableResult
    static func claimStatusLine() throws -> Bool {
        try claimStatusLine(at: defaultClaudeAccount)
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

    /// A foreign statusLine is claimable only when it is an orphan: every
    /// filesystem path it names is gone (e.g. another notch app that owned
    /// the slot was uninstalled). A live command — anything still pointing
    /// at an existing file — is left untouched.
    private static func statusLineIsOrphan(_ command: String) -> Bool {
        let fm = FileManager.default
        let paths = command
            .split(whereSeparator: { $0 == " " || $0 == "'" || $0 == "\"" })
            .map { $0.hasPrefix("~") ? home + $0.dropFirst() : String($0) }
            .filter { $0.hasPrefix("/") }
        // No path at all is unusual; don't claim in that ambiguous case.
        guard !paths.isEmpty else { return false }
        return !paths.contains { fm.fileExists(atPath: $0) }
    }

    private static func removalKey(for codexHome: CodexHome) -> String {
        codexHome.isDefault ? codexRemovalKey : "\(codexRemovalKey).\(codexHome.path)"
    }

}

extension Notification.Name {
    /// Posted when the Claude account registry changes.
    static let vedettaClaudeAccountsChanged = Notification.Name("vedettaClaudeAccountsChanged")
}
