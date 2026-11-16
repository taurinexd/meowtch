import AVFAudio
import Foundation
import VedettaKit

/// The listening side of CALL mode: owns both captures and publishes what
/// the notch shows. Everything stays in memory.
@MainActor
final class CallSession: ObservableObject {
    static let shared = CallSession()

    @Published private(set) var isListening = false
    @Published private(set) var problem: CallListenProblem?
    /// Last buffer level per channel, for the debug socket and a level hint.
    @Published private(set) var clientLevel: Double = 0
    @Published private(set) var meLevel: Double = 0

    private var systemTap: AnyObject?
    private var microphone: MicrophoneCapture?
    private var consumers: [Task<Void, Never>] = []

    func start() {
        guard !isListening else { return }
        problem = nil
        guard #available(macOS 14.2, *) else {
            problem = .requiresMacOS26
            return
        }
        isListening = true
        Task { await self.startCaptures() }
    }

    func stop() {
        consumers.forEach { $0.cancel() }
        consumers = []
        if #available(macOS 14.2, *) { (systemTap as? SystemAudioTap)?.stop() }
        systemTap = nil
        microphone?.stop()
        microphone = nil
        clientLevel = 0
        meLevel = 0
        isListening = false
    }

    @available(macOS 14.2, *)
    private func startCaptures() async {
        do {
            let mic = MicrophoneCapture()
            let meStream = try await mic.start()
            microphone = mic
            let tap = SystemAudioTap()
            let clientStream = try tap.start()
            systemTap = tap
            consume(clientStream, speaker: .client)
            consume(meStream, speaker: .me)
        } catch CallAudioError.problem(let problem) {
            stop()
            self.problem = problem
        } catch {
            stop()
            NSLog("Vedetta call: capture failed: %@", String(describing: error))
            self.problem = .noMeetingAudio
        }
    }

    private func consume(_ stream: AsyncStream<CallAudioChunk>, speaker: CallSpeaker) {
        consumers.append(Task { [weak self] in
            for await chunk in stream {
                let level = chunk.buffer.rmsLevel
                await MainActor.run {
                    guard let self else { return }
                    if speaker == .client { self.clientLevel = level } else { self.meLevel = level }
                }
            }
        })
    }
}
