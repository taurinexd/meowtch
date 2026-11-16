import AVFAudio
import Combine
import CoreAudio
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
    /// Whether the default output is private to the user's ears; read when
    /// listening starts (spec: headphones are a stated precondition).
    @Published private(set) var headphones = true
    /// Last time each channel's level crossed `CallCopilot.speechRMS`: the
    /// trigger's sense of who is speaking, faster than the transcriber.
    private(set) var lastLoudClient: Date?
    private(set) var lastLoudMe: Date?

    private var systemTap: AnyObject?
    private var microphone: MicrophoneCapture?
    private var consumers: [Task<Void, Never>] = []
    private var transcribers: [AnyObject] = []
    private var modeObserver: AnyCancellable?
    private var clientPeak: Double = 0
    private var silenceWatch: Task<Void, Never>?

    private init() {
        // Leaving CALL ends listening: the microphone never stays on in CODE.
        modeObserver = ScreenPrivacy.shared.$mode.sink { mode in
            guard mode == .code else { return }
            Task { @MainActor in CallSession.shared.stop() }
        }
    }

    func start() {
        guard !isListening else { return }
        problem = nil
        guard #available(macOS 26, *) else {
            problem = .requiresMacOS26
            return
        }
        headphones = Self.defaultOutputIsHeadphones()
        isListening = true
        CallCopilot.shared.start()
        Task { await self.startCaptures() }
    }

    func stop() {
        CallCopilot.shared.stop()
        lastLoudClient = nil
        lastLoudMe = nil
        silenceWatch?.cancel()
        silenceWatch = nil
        clientPeak = 0
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
            watchForSilentClient()
        } catch CallAudioError.problem(let problem) {
            stop()
            self.problem = problem
        } catch {
            stop()
            NSLog("Vedetta call: capture failed: %@", String(describing: error))
            self.problem = .noMeetingAudio
        }
    }

    /// A denied system-audio permission yields silence, not an error: check
    /// once, after the threshold, whether the meeting app is playing into a
    /// tap that has heard nothing at all.
    @available(macOS 14.2, *)
    private func watchForSilentClient() {
        let started = Date()
        silenceWatch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, self.isListening else { return }
            let playing = SystemAudioTap.audioProcesses().contains { process in
                process.isRunningOutput
                    && !CallAudioRules.meetingProcesses([process], excludingPID: getpid()).isEmpty
            }
            if let problem = CallAudioRules.silentClientProblem(
                listeningFor: Date().timeIntervalSince(started),
                clientPeak: self.clientPeak, meetingPlaying: playing
            ) {
                self.problem = problem
            }
        }
    }

    /// Reads the default output device's transport and data source.
    private static func defaultOutputIsHeadphones() -> Bool {
        guard let device: AudioObjectID = scalarProperty(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice
        ) else { return false }
        let transport: UInt32 = scalarProperty(device, kAudioDevicePropertyTransportType) ?? 0
        let source: UInt32? = scalarProperty(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        return CallAudioRules.isHeadphoneOutput(transportType: transport, dataSource: source)
    }

    /// Debug: transcribes an audio file as if it were the client channel,
    /// silently and repeatably (no playback). Used to measure punctuation and
    /// latency on known Italian speech.
    func transcribeFile(_ url: URL) {
        guard #available(macOS 26, *) else { problem = .requiresMacOS26; return }
        stop()
        isListening = true
        CallCopilot.shared.start()
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
                    let loud = level >= CallCopilot.speechRMS
                    if speaker == .client {
                        self.clientLevel = level
                        self.clientPeak = max(self.clientPeak, level)
                        if loud { self.lastLoudClient = Date() }
                    } else {
                        self.meLevel = level
                        if loud { self.lastLoudMe = Date() }
                    }
                }
            }
            forwardContinuation.finish()
        })
    }
}
