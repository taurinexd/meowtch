import Foundation

/// Every user-tunable preference key, with its default. Names mirror the
/// original's defaults (verified in the VI binary: hoverToExpandEnabled,
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
            SettingsKey.soundVolume: 0.5,
        ])
    }
}
