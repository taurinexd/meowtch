import AVFoundation
import Foundation

/// 8-bit synthesized alerts: square-wave chirps generated in memory,
/// one motif per event. Custom packs (M7) can override each event with a
/// file named after it in ~/.vedetta/custom-sounds/.
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    enum Event: String {
        case approvalRequest = "approval-request"
        case question = "question"
        case sessionComplete = "session-complete"
    }

    private var players: [AVAudioPlayer] = []
    private let defaults = UserDefaults.standard
    private let mutedKey = "soundsMuted"

    var isMuted: Bool {
        get { defaults.bool(forKey: mutedKey) }
        set { defaults.set(newValue, forKey: mutedKey) }
    }

    func play(_ event: Event) {
        guard !isMuted else { return }

        let customPath = NSHomeDirectory() + "/.vedetta/custom-sounds/\(event.rawValue).wav"
        let data: Data
        if let custom = FileManager.default.contents(atPath: customPath) {
            data = custom
        } else {
            data = Self.motif(for: event)
        }

        guard let player = try? AVAudioPlayer(data: data) else { return }
        let volume = defaults.object(forKey: SettingsKey.soundVolume) as? Double ?? 0.5
        player.volume = Float(volume)
        player.play()
        players.append(player)
        players.removeAll { !$0.isPlaying && $0 !== player }
    }

    // MARK: - Synthesis

    private static func motif(for event: Event) -> Data {
        switch event {
        case .approvalRequest:
            return wav(notes: [(660, 0.07), (0, 0.02), (880, 0.10)])
        case .question:
            return wav(notes: [(660, 0.07), (0, 0.02), (660, 0.07)])
        case .sessionComplete:
            return wav(notes: [(880, 0.06), (0, 0.02), (1320, 0.09)])
        }
    }

    /// Renders square-wave notes ((frequency Hz, duration s); 0 Hz = rest)
    /// into a 16-bit mono WAV.
    private static func wav(notes: [(Double, Double)], sampleRate: Double = 22_050) -> Data {
        var samples: [Int16] = []
        for (frequency, duration) in notes {
            let count = Int(duration * sampleRate)
            for i in 0..<count {
                guard frequency > 0 else { samples.append(0); continue }
                let phase = Double(i) * frequency / sampleRate
                let envelope = min(1.0, Double(count - i) / (sampleRate * 0.015))
                let value = (phase.truncatingRemainder(dividingBy: 1) < 0.5 ? 1.0 : -1.0)
                samples.append(Int16(value * envelope * 9_000))
            }
        }

        var data = Data()
        let byteCount = samples.count * 2
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + byteCount))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(16)
        append16(1)                       // PCM
        append16(1)                       // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))    // byte rate
        append16(2)                       // block align
        append16(16)                      // bits
        data.append(contentsOf: "data".utf8)
        append(UInt32(byteCount))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
