import AVFoundation
import Foundation
import VedettaKit

/// Matteo's voice: the default input through `AVAudioEngine`. Asks for
/// microphone access on first use; a refusal surfaces as a notch message.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<CallAudioChunk>.Continuation?

    func start() async throws -> AsyncStream<CallAudioChunk> {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw CallAudioError.problem(.microphoneDenied)
            }
        default:
            throw CallAudioError.problem(.microphoneDenied)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: CallAudioChunk.self, bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        let input = engine.inputNode
        // Apple's echo cancellation: removes what the speakers play (the
        // meeting) from the mic, so on speakers the "me" channel stays
        // Matteo's voice. Must be set while the engine is stopped. Ducking
        // at its minimum, so the meeting audio is not turned down.
        do {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min
            )
        } catch {
            NSLog("Vedetta call: voice processing unavailable: %@", String(describing: error))
        }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let copy = buffer.deepCopy() { continuation.yield(CallAudioChunk(buffer: copy)) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw CallAudioError.status("microphone engine: \(error.localizedDescription)", 0)
        }
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
