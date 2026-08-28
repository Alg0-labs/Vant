import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow

            if case .error(let message) = appState.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            transcriptionPathRow

            if !appState.permissions.microphoneAuthorized || !appState.permissions.accessibilityTrusted {
                Divider()
                permissionsSection
            }

            Divider()

            Button("Quit Vant") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var statusRow: some View {
        HStack {
            Image(systemName: appState.phase.menuBarSymbol)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.headline)
        }
    }

    private var statusColor: Color {
        switch appState.phase {
        case .idle: return .primary
        case .recording: return .red
        case .processing: return .blue
        case .error: return .orange
        }
    }

    private var statusText: String {
        switch appState.phase {
        case .idle: return "Ready — hold ⌃Space to dictate"
        case .recording: return "Recording… release ⌃Space to stop"
        case .processing: return "Cleaning up…"
        case .error: return "Needs attention"
        }
    }

    /// Surfaces which transcription path is in use. Worth showing: the
    /// fallback path is several times slower, and without this the user has
    /// no way to tell why dictation suddenly feels sluggish.
    @ViewBuilder
    private var transcriptionPathRow: some View {
        if appState.permissions.speechRecognitionAuthorized {
            Label("On-device transcription", systemImage: "bolt.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Cloud transcription — slower", systemImage: "cloud")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        if !appState.permissions.microphoneAuthorized {
            permissionRow(title: "Microphone access needed") {
                appState.permissions.openMicrophoneSettings()
            }
        }
        if !appState.permissions.accessibilityTrusted {
            permissionRow(title: "Accessibility access needed") {
                appState.permissions.openAccessibilitySettings()
            }
        }
    }

    private func permissionRow(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "gearshape")
                .font(.caption)
        }
        .buttonStyle(.plain)
    }
}
