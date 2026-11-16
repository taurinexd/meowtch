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
    @Published private(set) var transcript = CallTranscript()

    private var systemTap: AnyObject?
    private var microphone: MicrophoneCapture?
    private var consumers: [Task<Void, Never>] = []
    private var transcribers: [AnyObject] = []

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
        if #available(macOS 26, *) {
            for case let transcriber as LiveTranscriber in transcribers {
                Task { await transcriber.stop() }
            }
        }
        transcribers = []
        transcript = CallTranscript()
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
            if #available(macOS 26, *) {
                try await LiveTranscriber.prepareAssets { fraction in
                    Task { @MainActor in
                        CallSession.shared.problem = .speechAssetDownloading(fraction: fraction)
                    }
                }
                guard isListening else { return }
                problem = nil
            }
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

    /// Debug: transcribes an audio file as if it were the client channel,
    /// silently and repeatably (no playback). Used to measure punctuation and
    /// latency on known Italian speech.
    func transcribeFile(_ url: URL) {
        guard #available(macOS 26, *) else { problem = .requiresMacOS26; return }
        stop()
        isListening = true
        Task {
            do {
                try await LiveTranscriber.prepareAssets { _ in }
                let file = try AVAudioFile(forReading: url)
                let (stream, continuation) = AsyncStream.makeStream(of: CallAudioChunk.self)
                consume(stream, speaker: .client)
                let frames: AVAudioFrameCount = 4096
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
                    try file.read(into: buffer, frameCount: frames)
                    continuation.yield(CallAudioChunk(buffer: buffer))
                    // Real-time pacing, so volatile results behave as live.
                    try await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate))
                }
                continuation.finish()
            } catch {
                NSLog("Vedetta call: file transcription failed: %@", String(describing: error))
            }
        }
    }

    /// Reads one capture: publishes its level and fans the audio out to
    /// that channel's transcriber (macOS 26+).
    private func consume(_ stream: AsyncStream<CallAudioChunk>, speaker: CallSpeaker) {
        let (forward, forwardContinuation) = AsyncStream.makeStream(of: CallAudioChunk.self, bufferingPolicy: .bufferingNewest(64))
        if #available(macOS 26, *) {
            let transcriber = LiveTranscriber(speaker: speaker)
            transcribers.append(transcriber)
            consumers.append(Task {
                do {
                    try await transcriber.run(forward) { update in
                        Task { @MainActor in
                            let session = CallSession.shared
                            guard session.isListening else { return }
                            session.transcript.apply(update)
                        }
                    }
                } catch {
                    NSLog("Vedetta call: transcription (%@) failed: %@", speaker.rawValue, String(describing: error))
                }
            })
        }
        consumers.append(Task { [weak self] in
            for await chunk in stream {
                forwardContinuation.yield(chunk)
                let level = chunk.buffer.rmsLevel
                await MainActor.run {
                    guard let self else { return }
                    if speaker == .client { self.clientLevel = level } else { self.meLevel = level }
                }
            }
            forwardContinuation.finish()
        })
    }
}
