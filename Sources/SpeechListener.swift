@preconcurrency import AVFoundation
import Speech

/// Streams the default microphone into Apple's on-device speech recognizer
/// and reports recognized words. Audio never leaves the Mac.
@MainActor
final class SpeechListener {
    enum ListenError: LocalizedError {
        case micDenied, noMicrophone, noAudioFormat
        var errorDescription: String? {
            switch self {
            case .micDenied: return "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
            case .noMicrophone: return "No microphone found."
            case .noAudioFormat: return "Speech recognition isn't available for English on this Mac."
            }
        }
    }

    /// Words of one recognizer result. `isFinal` false means the recognizer
    /// may still revise them; the next result for the same audio replaces them.
    var onWords: ((_ words: [String], _ isFinal: Bool) -> Void)?
    var onStatus: ((String?) -> Void)?

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private(set) var isListening = false

    func start() async throws {
        guard !isListening else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw ListenError.micDenied }
        _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }

        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus?("Downloading speech model…")
            try await request.downloadAndInstall()
            onStatus?(nil)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ListenError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let engine = AVAudioEngine()
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw ListenError.noMicrophone }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat,
                                    block: Self.makeTap(from: micFormat, to: format, into: continuation))
        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let words = String(result.text.characters).split(whereSeparator: \.isWhitespace).map(String.init)
                    self?.onWords?(words, result.isFinal)
                }
            } catch {
                self?.onStatus?(error.localizedDescription)
            }
        }
        self.engine = engine
        self.analyzer = analyzer
        self.input = continuation
        isListening = true
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        input?.finish()
        let analyzer = self.analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        resultsTask?.cancel()
        engine = nil; self.analyzer = nil; input = nil; resultsTask = nil
    }

    /// Built outside the main actor: the tap runs on a realtime audio thread.
    nonisolated private static func makeTap(
        from micFormat: AVAudioFormat, to format: AVAudioFormat,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) -> AVAudioNodeTapBlock {
        let converter = AVAudioConverter(from: micFormat, to: format)
        return { buffer, _ in
            guard let converter else { return }
            let ratio = format.sampleRate / micFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }
    }
}
