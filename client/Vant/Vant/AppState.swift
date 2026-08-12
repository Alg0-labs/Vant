import Foundation

enum DictationPhase: Equatable {
    case idle
    case recording
    case processing
    case error(String)

    var menuBarSymbol: String {
        switch self {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .processing: return "waveform"
        case .error: return "exclamationmark.triangle"
        }
    }
}

/// Orchestrates the push-to-talk record → transcribe → clean → paste flow
/// and owns the state the menu bar and visualizer render.
///
/// Two transcription paths exist, chosen per dictation:
///
/// - **Fast (default):** `SpeechTranscriber` recognizes speech on-device
///   *while* the user talks, so at key-release only the Claude cleanup
///   remains (`POST /api/v1/format`). This is what keeps latency near a
///   second instead of ~4.
/// - **Fallback:** if on-device recognition is unavailable or unauthorized,
///   `AudioRecorder` captures audio and the backend runs Whisper then
///   Claude (`POST /api/v1/dictate`). Slower, but more robust on accents
///   and in noisy rooms.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var phase: DictationPhase = .idle

    /// Microphone amplitude, 0...1, republished at ~30 Hz while recording
    /// so the visualizer tracks real audio.
    @Published private(set) var audioLevel: Float = 0

    /// Rolling window of recent levels, oldest first — the visualizer's bar
    /// heights. Maintained here rather than in the view so the view stays a
    /// pure function of state and needs no per-frame mutation.
    @Published private(set) var levelHistory: [Float] = Array(repeating: 0, count: AppState.levelHistoryLength)

    static let levelHistoryLength = 34

    let permissions = PermissionsManager()

    private let transcriber = SpeechTranscriber()
    private let audioRecorder = AudioRecorder()
    private let backendClient = BackendClient()
    private var hotkeyManager: HotkeyManager?
    private var levelTimer: Timer?

    /// Which path the in-flight dictation is using.
    private enum CaptureMode { case onDevice, audioUpload }
    private var captureMode: CaptureMode = .onDevice

    /// The app that had focus when the current recording started. Captured
    /// at press time rather than on completion, because by the time the
    /// transcript comes back the user may well have switched away.
    private var focusAtRecordingStart: FocusContext?

    private init() {}

    /// Called once at launch: pre-warms the recorder, registers the global
    /// hotkey, and requests the permissions dictation needs.
    func start() {
        guard hotkeyManager == nil else { return }

        audioRecorder.prepareNext()

        let manager = HotkeyManager(
            onPress: { [weak self] in
                Task { @MainActor in self?.hotkeyPressed() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in self?.hotkeyReleased() }
            }
        )
        manager.register()
        hotkeyManager = manager

        permissions.requestMicrophoneAccess()
        Task { await permissions.requestSpeechRecognition() }
    }

    func hotkeyPressed() {
        switch phase {
        case .idle, .error:
            beginRecording()
        case .recording, .processing:
            break // key repeat / already active — ignore
        }
    }

    func hotkeyReleased() {
        guard case .recording = phase else { return } // stray release with no matching press
        finishRecording()
    }

    /// Equivalent to releasing the hotkey — wired to the visualizer's Stop
    /// button.
    func stopButtonTapped() {
        hotkeyReleased()
    }

    // MARK: - Recording

    private func beginRecording() {
        guard permissions.microphoneAuthorized else {
            phase = .error("Microphone access is required.")
            permissions.requestMicrophoneAccess()
            return
        }
        guard permissions.accessibilityTrusted else {
            phase = .error("Accessibility access is required to paste dictated text.")
            permissions.requestAccessibilityAccess()
            return
        }

        focusAtRecordingStart = FocusContext.current()

        if transcriber.isAvailable {
            do {
                try transcriber.start()
                captureMode = .onDevice
                phase = .recording
                startLevelPolling()
                return
            } catch {
                // Fall through to the audio-upload path rather than failing
                // the dictation outright.
                NSLog("Vant: on-device transcription unavailable (\(error.localizedDescription)); using audio upload")
            }
        }

        do {
            try audioRecorder.startRecording()
            captureMode = .audioUpload
            phase = .recording
            startLevelPolling()
        } catch {
            phase = .error("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    private func finishRecording() {
        let focus = focusAtRecordingStart
        focusAtRecordingStart = nil
        stopLevelPolling()

        switch captureMode {
        case .onDevice:
            phase = .processing
            Task {
                let transcript = await transcriber.stopAndFinish()
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    phase = .idle // nothing was said
                    return
                }
                await deliver { try await self.backendClient.format(text: transcript, focus: focus) }
            }

        case .audioUpload:
            guard let fileURL = audioRecorder.stopRecording() else {
                phase = .idle
                return
            }
            phase = .processing
            Task {
                defer { try? FileManager.default.removeItem(at: fileURL) }
                await deliver { try await self.backendClient.dictate(audioFileURL: fileURL, focus: focus) }
            }
        }
    }

    /// Runs a backend call and pastes its result, mapping failures onto the
    /// error phase. Nothing is ever pasted on failure.
    private func deliver(_ work: () async throws -> String) async {
        do {
            let text = try await work()
            if !text.isEmpty {
                TextInjector.paste(text)
            }
            phase = .idle
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Level polling

    /// Republishes the active capture path's level at ~30 Hz. Polling is
    /// deliberate: the audio tap runs on a realtime thread and must not hop
    /// to the main actor per buffer (hundreds of times a second).
    private func startLevelPolling() {
        levelTimer?.invalidate()
        levelHistory = Array(repeating: 0, count: Self.levelHistoryLength)
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let level = switch self.captureMode {
                case .onDevice: self.transcriber.level
                case .audioUpload: self.audioRecorder.level
                }
                self.audioLevel = level

                // Newest sample enters on the right; history scrolls left.
                // The floor keeps a visible idle heartbeat during silence
                // rather than a dead flat line.
                var next = self.levelHistory
                next.removeFirst()
                next.append(max(0.05, level))
                self.levelHistory = next
            }
        }
    }

    private func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
    }
}
