import Foundation

/// One Core Audio process object, as the tap code reads it from the HAL.
public struct AudioProcessInfo: Sendable, Equatable {
    public let objectID: UInt32
    public let pid: Int32
    public let bundleID: String?
    public let isRunningOutput: Bool

    public init(objectID: UInt32, pid: Int32, bundleID: String?, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

/// Pure decisions behind CALL listening: which processes carry the meeting,
/// whether the output is private to the user's ears, what to say when
/// something is missing.
public enum CallAudioRules {
    /// Apps a meeting runs in. Prefixes, so helper processes match too:
    /// Chrome plays a Meet call from `com.google.Chrome.helper`, not from
    /// the main app.
    static let meetingBundlePrefixes = [
        "com.google.Chrome", "com.apple.Safari", "com.apple.WebKit",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime",
    ]

    /// Process objects to tap for the client's voice. Among the meeting apps,
    /// the ones playing audio right now win; if none is, all of them. Empty
    /// means "no meeting app found": the caller falls back to a global tap
    /// that excludes Meowtch itself.
    public static func meetingProcesses(_ all: [AudioProcessInfo], excludingPID own: Int32) -> [UInt32] {
        let candidates = all.filter { process in
            guard process.pid != own, let bundle = process.bundleID else { return false }
            return meetingBundlePrefixes.contains { bundle.hasPrefix($0) }
        }
        let playing = candidates.filter(\.isRunningOutput)
        return (playing.isEmpty ? candidates : playing).map(\.objectID)
    }

    /// Headphones keep the client's voice out of the microphone. Bluetooth
    /// and USB devices count; the built-in output only when its data source
    /// is the headphone jack.
    public static func isHeadphoneOutput(transportType: UInt32, dataSource: UInt32?) -> Bool {
        switch transportType {
        case fourCC("blue"), fourCC("blea"), fourCC("usb "):
            return true
        case fourCC("bltn"):
            return dataSource == fourCC("hdpn")
        default:
            return false
        }
    }

    /// Seconds of digital silence on the client channel, while a meeting app
    /// is playing, before calling it a denied permission.
    static let silentClientThreshold: TimeInterval = 8

    /// A denied "System Audio Recording" permission does not fail: the tap
    /// just delivers zeros. Exact silence while the meeting app is playing
    /// for a few seconds is that case, said out loud instead of waiting.
    public static func silentClientProblem(
        listeningFor seconds: TimeInterval, clientPeak: Double, meetingPlaying: Bool
    ) -> CallListenProblem? {
        guard seconds >= silentClientThreshold, meetingPlaying, clientPeak == 0 else { return nil }
        return .systemAudioDenied
    }

    static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// Why listening cannot start (or is not ready yet), as the notch says it.
public enum CallListenProblem: Equatable, Sendable {
    case requiresMacOS26
    case microphoneDenied
    case systemAudioDenied
    case noMeetingAudio
    case speechAssetDownloading(fraction: Double)
    case speechUnavailable

    public var message: String {
        switch self {
        case .requiresMacOS26:
            "Listening requires macOS 26."
        case .microphoneDenied:
            "Microphone access is off. System Settings › Privacy & Security › Microphone › Meowtch."
        case .systemAudioDenied:
            "Meeting audio access is off. System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only › Meowtch."
        case .noMeetingAudio:
            "No meeting audio found. Start the call first, then listen."
        case .speechAssetDownloading(let fraction):
            "Downloading Italian speech model… \(Int(fraction * 100))%"
        case .speechUnavailable:
            "Italian transcription is not available on this Mac."
        }
    }
}
