import AVFAudio
import Foundation
import Speech
import VedettaKit

/// One channel's live transcription: a `SpeechAnalyzer` with an Italian
/// `SpeechTranscriber`, fed by a capture stream converted to the analyzer's
/// preferred format. On-device only; nothing leaves the Mac.
@available(macOS 26, *)
final class LiveTranscriber: @unchecked Sendable {
    let speaker: CallSpeaker
    let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    init(speaker: CallSpeaker, locale: Locale = Locale(identifier: "it-IT")) {
        self.speaker = speaker
        self.locale = locale
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: []
        )
    }

    /// Makes sure the Italian model is on disk, downloading it through the
    /// system on first use. `progress` gets 0…1 while downloading.
    static func prepareAssets(
        locale: Locale = Locale(identifier: "it-IT"),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw CallAudioError.problem(.speechUnavailable)
        }
        let transcriber = makeTranscriber(supported)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return  // already installed
        }
        let reporter = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
    }

    /// Transcribes `audio` until it ends or `stop()` is called.
    func run(
        _ audio: AsyncStream<CallAudioChunk>,
        onUpdate: @escaping @Sendable (CallTranscript.Update) -> Void
    ) async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: self.locale) ?? self.locale
        let transcriber = Self.makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CallAudioError.problem(.speechUnavailable)
        }
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation
        try await analyzer.start(inputSequence: inputs)

        let speaker = self.speaker
        let results = Task {
            for try await result in transcriber.results {
                onUpdate(CallTranscript.Update(
                    speaker: speaker, text: String(result.text.characters),
                    isFinal: result.isFinal, at: Date()
                ))
            }
        }

        var converter: AVAudioConverter?
        for await chunk in audio {
            let buffer = chunk.buffer
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target)
            }
            guard let converter, let converted = Self.convert(buffer, with: converter, to: target) else { continue }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        continuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await results.result
    }

    func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
    }

    /// Sample-rate / channel conversion of one buffer.
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
