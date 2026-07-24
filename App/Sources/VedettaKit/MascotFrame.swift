import Foundation

/// The guard-cat mascot: 8×7 pixel patterns and pure per-state frame
/// selection. Rendering stays in the app (PixelSprite); this type only
/// decides WHICH pattern is visible at a given instant. `o` marks an eye:
/// an unlit pixel, the renderer treats it like `.`.
public enum MascotFrame {
    public static let base: [String] = [
        ".#....#.",
        ".##..##.",
        ".######.",
        ".#o##o#.",
        ".######.",
        "..####..",
        "..#..#..",
    ]
    public static let lookLeft = row(base, 3, ".o##o##.")
    public static let lookRight = row(base, 3, ".##o##o.")
    public static let wideEyes = row(base, 4, ".#o##o#.")
    public static let closedEyes = row(row(base, 3, ".######."), 4, ".#o##o#.")
    public static let twitch = row(base, 0, "..#...#.")

    /// Eye-scan step for running/compacting.
    public static let scanStep: TimeInterval = 0.36
    /// The ear twitch plays two bursts inside this window after a state change.
    public static let twitchWindow: TimeInterval = 0.45

    public static func frame(
        state: SessionState,
        now: Date,
        stateChangedAt: Date,
        blinkOn: Bool
    ) -> [String] {
        let sinceChange = now.timeIntervalSince(stateChangedAt)
        if state != .completed, sinceChange >= 0, sinceChange < twitchWindow,
           sinceChange < 0.14 || (sinceChange > 0.28 && sinceChange < 0.42) {
            return twitch
        }
        switch state {
        case .running, .compacting:
            let tick = Int(now.timeIntervalSinceReferenceDate / scanStep)
            let seq = [base, lookLeft, base, lookRight]
            return seq[((tick % 4) + 4) % 4]
        case .waitingForInput:
            return blinkOn ? base : closedEyes
        case .needsApproval:
            return wideEyes
        case .completed:
            return closedEyes
        }
    }

    private static func row(_ pattern: [String], _ index: Int, _ line: String) -> [String] {
        var copy = pattern
        copy[index] = line
        return copy
    }
}
