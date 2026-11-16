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
