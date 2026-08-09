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

/// Orchestrates the push-to-talk record → upload → paste flow and owns the
/// phase the menu bar UI and the floating recording indicator render.
///
/// Recording is push-to-talk, not toggle: `hotkeyPressed()` starts it,
/// `hotkeyReleased()` (or the indicator's Stop button, via
/// `stopButtonTapped()`) ends it. Recording lasts exactly as long as the
/// key is physically held, which removes the "did my second tap register"
/// ambiguity a toggle has — the usual cause of a dictation getting cut off
/// mid-sentence.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var phase: DictationPhase = .idle

    let permissions = PermissionsManager()

    private let audioRecorder = AudioRecorder()
    private let backendClient = BackendClient()
    private var hotkeyManager: HotkeyManager?

    /// The app that had focus when the current recording started. Captured
    /// at press time rather than on completion, because by the time the
    /// transcript comes back the user may well have switched away.
    private var focusAtRecordingStart: FocusContext?

    private init() {}

    /// Called once at launch: pre-warms the recorder, registers the global
    /// hotkey, and kicks off the initial microphone permission check.
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

    /// Equivalent to releasing the hotkey — wired to the floating
    /// indicator's Stop button.
    func stopButtonTapped() {
        hotkeyReleased()
    }

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

        do {
            try audioRecorder.startRecording()
            phase = .recording
        } catch {
            phase = .error("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    private func finishRecording() {
        guard let fileURL = audioRecorder.stopRecording() else {
            phase = .idle
            return
        }
        let focus = focusAtRecordingStart
        focusAtRecordingStart = nil
        phase = .processing

        Task {
            defer { try? FileManager.default.removeItem(at: fileURL) }
            do {
                let text = try await backendClient.dictate(audioFileURL: fileURL, focus: focus)
                if !text.isEmpty {
                    TextInjector.paste(text)
                }
                phase = .idle
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }
}
