import AVFoundation
import Foundation

/// Records microphone input to a temporary AAC file at the sample rate and
/// channel layout the backend expects for upload to Whisper.
///
/// For push-to-talk, the gap between "key pressed" and "recorder actually
/// capturing audio" eats the first word if it isn't hidden. `AVAudioRecorder`
/// spends most of that latency in `prepareToRecord()` (allocating buffers,
/// opening the audio hardware), not in `record()` itself — so a fresh
/// recorder is kept pre-prepared and idle at all times; `startRecording()`
/// just calls `record()` on it.
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var currentFileURL: URL?

    private var pendingRecorder: AVAudioRecorder?
    private var pendingFileURL: URL?

    private var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 12_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
    }

    /// Builds and prepares (but does not start) the recorder that the next
    /// `startRecording()` call will use. Safe to call repeatedly; call it
    /// once at launch and again after every `stopRecording()`.
    func prepareNext() {
        guard pendingRecorder == nil else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vant-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return }
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()

        pendingRecorder = recorder
        pendingFileURL = url
    }

    /// Starts recording to the pre-warmed file (or, if none is ready yet,
    /// falls back to preparing one on the spot) and returns its URL.
    @discardableResult
    func startRecording() throws -> URL {
        let recorder: AVAudioRecorder
        let url: URL

        if let pendingRecorder, let pendingFileURL {
            recorder = pendingRecorder
            url = pendingFileURL
        } else {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("vant-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()
        }
        pendingRecorder = nil
        pendingFileURL = nil

        guard recorder.record() else {
            throw AudioRecorderError.failedToStart
        }

        self.recorder = recorder
        self.currentFileURL = url
        return url
    }

    /// Stops the current recording, returns the file it was written to (or
    /// nil if nothing was recording), and immediately arms the next
    /// pre-warmed recorder for the following push-to-talk press.
    @discardableResult
    func stopRecording() -> URL? {
        recorder?.stop()
        let url = currentFileURL
        recorder = nil
        currentFileURL = nil
        prepareNext()
        return url
    }

    var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    /// Normalized microphone level, 0...1, for the visualizer on the
    /// fallback path. Mapped across the same 50 dB window the on-device
    /// transcriber uses so both paths look identical on screen.
    var level: Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        return max(0, min(1, (db + 50) / 50))
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case failedToStart

    var errorDescription: String? {
        "Couldn't start the audio recorder."
    }
}
