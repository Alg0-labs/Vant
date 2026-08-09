import AppKit
import Combine
import SwiftUI

/// Owns a small floating, non-activating panel that appears near the top
/// of the screen whenever a dictation is recording or being cleaned up —
/// an on-screen signal beyond the menu bar icon, plus a Stop button as an
/// alternative to releasing the hotkey.
///
/// The panel is deliberately non-activating (`.nonactivatingPanel`) so it
/// never steals keyboard focus from whatever app the user is dictating
/// into — stealing focus would both be disruptive and defeat the point of
/// pasting into "whatever app has focus."
@MainActor
final class RecordingIndicatorController {
    static let shared = RecordingIndicatorController()

    private var panel: NSPanel?
    private var cancellable: AnyCancellable?

    private init() {}

    func start() {
        guard cancellable == nil else { return }
        cancellable = AppState.shared.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.update(for: phase)
            }
    }

    private func update(for phase: DictationPhase) {
        switch phase {
        case .recording, .processing:
            show(phase: phase)
        case .idle, .error:
            hide()
        }
    }

    private func show(phase: DictationPhase) {
        let panel = panel ?? makePanel()
        self.panel = panel

        panel.contentView = NSHostingView(
            rootView: RecordingIndicatorView(phase: phase, onStop: {
                AppState.shared.stopButtonTapped()
            })
        )
        position(panel)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height - 12
        )
        panel.setFrameOrigin(origin)
    }
}

private struct RecordingIndicatorView: View {
    let phase: DictationPhase
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            if case .recording = phase {
                Spacer(minLength: 8)
                Button("Stop", action: onStop)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 240, height: 60, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(radius: 8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch phase {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
        case .processing:
            ProgressView()
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var label: String {
        switch phase {
        case .recording: return "Recording…"
        case .processing: return "Cleaning up…"
        default: return ""
        }
    }
}
