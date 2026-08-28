import AVFoundation
import Foundation
import Speech

/// Transcribes speech **on-device, while the user is still talking**, using
/// Apple's Speech framework fed from a live `AVAudioEngine` tap.
///
/// This is the fast path, and the reason dictation feels instant: a cloud
/// transcription round trip costs ~1.2-1.9s *after* the user stops
/// speaking, whereas on-device recognition runs concurrently with speech
/// and has a final transcript ready within a couple hundred milliseconds
/// of release. The backend then only has to run the Claude cleanup.
///
/// Accuracy is the trade: Whisper handles heavy accents and noisy rooms
/// better. `AudioRecorder` + `POST /api/v1/dictate` remains as the
/// fallback whenever on-device recognition isn't available.
///
/// The same audio tap doubles as the level source for the visualizer, so
/// the bars track real microphone amplitude rather than a fake animation.
final class SpeechTranscriber {
    enum TranscriberError: Error, LocalizedError {
        case unavailable
        case notAuthorized
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "On-device speech recognition isn't available."
            case .notAuthorized:
                return "Speech recognition permission was not granted."
            case .engineFailed(let detail):
                return "Audio engine failed: \(detail)"
            }
        }
    }

    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Guards the fields written from the realtime audio thread and the
    /// recognition callback, both of which run off the main actor.
    private let lock = NSLock()
    private var _level: Float = 0
    private var _latestTranscript: String = ""
    private var _isFinal = false

    init(locale: Locale = Locale.current) {
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        self.recognizer = recognizer
    }

    /// True when on-device recognition can actually be used right now.
    var isAvailable: Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable
            && recognizer.supportsOnDeviceRecognition
            && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Normalized microphone level, 0...1. Read from the UI at frame rate;
    /// written from the audio thread.
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return _level
    }

    /// Best transcript so far — a partial result while speaking, the final
    /// result once recognition settles.
    var currentTranscript: String {
        lock.lock()
        defer { lock.unlock() }
        return _latestTranscript
    }

    // MARK: - Lifecycle

    func start() throws {
        guard let recognizer, recognizer.isAvailable else { throw TranscriberError.unavailable }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriberError.notAuthorized
        }

        lock.lock()
        _latestTranscript = ""
        _isFinal = false
        _level = 0
        lock.unlock()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep audio on the machine. Also what makes this fast — no upload.
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.lock.lock()
                self._latestTranscript = result.bestTranscription.formattedString
                if result.isFinal { self._isFinal = true }
                self.lock.unlock()
            }
            if error != nil {
                self.lock.lock()
                self._isFinal = true
                self.lock.unlock()
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            self.updateLevel(from: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanUpAudio()
            throw TranscriberError.engineFailed(error.localizedDescription)
        }
    }

    /// Stops capture and returns the transcript.
    ///
    /// After `endAudio()` the recognizer usually needs a beat to promote
    /// its last partial into a final result. We wait only briefly and then
    /// take the best partial: a marginally less-polished transcript beats
    /// adding hundreds of milliseconds to a latency-critical path, and the
    /// Claude cleanup pass repairs punctuation anyway.
    func stopAndFinish(maxWait: TimeInterval = 0.35) async -> String {
        cleanUpAudio()
        request?.endAudio()

        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            if hasFinalResult() { break }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }

        let transcript = currentTranscript

        task?.cancel()
        task = nil
        request = nil
        resetLevel()

        return transcript
    }

    // Synchronous accessors: NSLock cannot be taken directly from an async
    // context under Swift 6 concurrency checking.
    private func hasFinalResult() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isFinal
    }

    private func resetLevel() {
        lock.lock()
        defer { lock.unlock() }
        _level = 0
    }

    /// Tears down capture without waiting for a transcript.
    func abort() {
        cleanUpAudio()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        resetLevel()
    }

    // MARK: - Internals

    private func cleanUpAudio() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Computes an RMS level and maps it onto a perceptually useful 0...1
    /// range. Runs on the realtime audio thread, so it stays arithmetic
    /// only — no allocation, no main-actor hops.
    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sumOfSquares: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(count))

        // dBFS, then normalized across a 50 dB window. Speech sits around
        // -30 dB, so this keeps the bars lively without clipping.
        let db = 20 * log10(max(rms, 0.000_000_1))
        let normalized = max(0, min(1, (db + 50) / 50))

        // Asymmetric smoothing: rise fast so consonants register, fall
        // slower so the bars decay instead of flickering.
        lock.lock()
        let smoothing: Float = normalized > _level ? 0.6 : 0.15
        _level += (normalized - _level) * smoothing
        lock.unlock()
    }

    // MARK: - Authorization

    /// Requests speech-recognition permission. Distinct from the microphone
    /// grant: macOS treats them as separate TCC services.
    static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
