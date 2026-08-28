import AVFoundation
import AppKit
import ApplicationServices
import Combine
import Speech

/// Tracks and requests the two permissions Vant needs: microphone
/// access to record, and Accessibility trust to inject text via CGEvent.
@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var accessibilityTrusted = false

    /// Speech recognition is a separate TCC service from the microphone.
    /// Without it Vant still works, but falls back to the slower
    /// upload-audio-to-Whisper path.
    @Published private(set) var speechRecognitionAuthorized = false

    private var accessibilityPollTimer: Timer?

    init() {
        refreshMicrophoneStatus()
        refreshAccessibilityStatus(prompt: false)
        speechRecognitionAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Requests speech-recognition access. Declining is non-fatal — it just
    /// costs latency, since dictation then routes through Whisper.
    func requestSpeechRecognition() async {
        let granted = await SpeechTranscriber.requestAuthorization()
        speechRecognitionAuthorized = granted
    }

    func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAuthorized = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.microphoneAuthorized = granted
                }
            }
        default:
            microphoneAuthorized = false
        }
    }

    /// Prompts the system Accessibility dialog (if not already trusted) and
    /// starts polling, since trust state isn't KVO-observable.
    func requestAccessibilityAccess() {
        refreshAccessibilityStatus(prompt: true)
        startPollingAccessibility()
    }

    func refreshMicrophoneStatus() {
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func openMicrophoneSettings() {
        openSystemSettings(pane: "Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openSystemSettings(pane: "Privacy_Accessibility")
    }

    private func refreshAccessibilityStatus(prompt: Bool) {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: [String: Any] = [promptKey: prompt]
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func startPollingAccessibility() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                if trusted != self.accessibilityTrusted {
                    self.accessibilityTrusted = trusted
                }
                if trusted {
                    self.accessibilityPollTimer?.invalidate()
                    self.accessibilityPollTimer = nil
                }
            }
        }
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    deinit {
        accessibilityPollTimer?.invalidate()
    }
}
