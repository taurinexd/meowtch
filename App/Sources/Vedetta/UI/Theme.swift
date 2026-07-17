import SwiftUI
import VedettaKit

/// Vedetta's retro-terminal look: black panel, monospace type,
/// one signal color per session state.
enum Theme {
    static let panelBackground = Color.black.opacity(0.94)
    static let cardBackground = Color.white.opacity(0.06)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.55)
    static let accent = Color(red: 0.75, green: 0.68, blue: 1.0)
    static let toolBlue = Color(red: 0.35, green: 0.6, blue: 1.0)
    static let claudeOrange = Color(red: 0.9, green: 0.6, blue: 0.3)
    /// Compacting purples, both sampled on the original (screenshot 2x):
    /// sprite #9D58EF, "Compacting · 29s" text #8E2FA4.
    static let compactingPurple = Color(red: 0.616, green: 0.345, blue: 0.937)
    static let compactingText = Color(red: 0.557, green: 0.184, blue: 0.643)

    static func color(for state: SessionState) -> Color {
        switch state {
        case .needsApproval: Color.orange
        case .waitingForInput: Color(red: 0.42, green: 0.78, blue: 0.48)
        case .running: toolBlue
        case .compacting: compactingPurple
        case .completed: Color.gray
        }
    }

    static func label(for state: SessionState) -> String {
        switch state {
        case .needsApproval: "APPROVAL"
        case .waitingForInput: "WAITING"
        case .running: "RUNNING"
        case .compacting: "COMPACTING"
        case .completed: "DONE"
        }
    }
}
