import Foundation

/// Every user-tunable preference key, with its default. Names mirror the
/// original's defaults (verified against the original: hoverToExpandEnabled,
/// hoverExpandDelay, autoCollapseOnMouseLeave, expandDwellSeconds,
/// disableClickToJump, …) so the audit can cross-check them 1:1.
enum SettingsKey {
    static let hoverToExpandEnabled = "hoverToExpandEnabled"
    static let hoverExpandDelay = "hoverExpandDelay"
    static let autoCollapseOnMouseLeave = "autoCollapseOnMouseLeave"
    /// Seconds the finished-session peek stays open without interaction.
    static let expandDwellSeconds = "expandDwellSeconds"
    static let expandPanelForCompletions = "expandPanelForCompletions"
    static let disableClickToJump = "disableClickToJump"
    static let showUsageLimits = "showUsageLimits"
    static let preferredUsageProvider = "preferredUsageProvider"
    static let lastUsageProvider = "lastUsageProvider"
    /// Opt-in network probe of the per-account Claude quota (the only
    /// network Vedetta ever touches; off = fully offline).
    static let claudeNetworkRefresh = "claudeNetworkRefresh"
    /// Consent for the daily GitHub Releases check (asked in onboarding).
    static let updateAutoCheck = "updateAutoCheck"
    /// Whether that consent has ever been asked — existing installs get
    /// the question once, at the first launch after updating.
    static let updateConsentAsked = "updateConsentAsked"
    static let soundVolume = "soundVolume"
    // Pre-existing keys, listed for the single source of truth:
    // "showSessionMetadata" (SessionMetadataPresentation.defaultsKey),
    // "panelDisplayExternal", "soundsMuted", "codexApprovalMode",
    // "deferClaudeApprovalsToNative", "archivedSessionIds".
}

enum SettingsDefaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.hoverToExpandEnabled: true,
            SettingsKey.hoverExpandDelay: 0.10,
            SettingsKey.autoCollapseOnMouseLeave: true,
            SettingsKey.expandDwellSeconds: 5,
            SettingsKey.expandPanelForCompletions: true,
            SettingsKey.disableClickToJump: false,
            SettingsKey.showUsageLimits: true,
            SettingsKey.preferredUsageProvider: "auto",
            SettingsKey.claudeNetworkRefresh: false,
            // Proposed on, but nothing happens until the user confirms in
            // onboarding (updateConsentAsked gates the first check).
            SettingsKey.updateAutoCheck: true,
            SettingsKey.updateConsentAsked: false,
            SettingsKey.soundVolume: 0.5,
        ])
    }
}
