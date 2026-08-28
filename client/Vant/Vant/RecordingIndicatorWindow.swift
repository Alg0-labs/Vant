import AppKit
import Combine
import SwiftUI

/// Owns a small floating, non-activating panel that appears while a
/// dictation is recording or being cleaned up.
///
/// The panel is deliberately non-activating (`.nonactivatingPanel`) so it
/// never steals keyboard focus from whatever app the user is dictating
/// into — stealing focus would both be disruptive and defeat the point of
/// pasting into "whatever app has focus."
@MainActor
final class RecordingIndicatorController {
    static let shared = RecordingIndicatorController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<VisualizerPanel>?
    private var cancellable: AnyCancellable?

    private static let panelSize = NSSize(width: 260, height: 76)

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
            show()
        case .idle, .error:
            hide()
        }
    }

    /// The panel is created once and kept around; SwiftUI observes
    /// `AppState` directly for phase and level changes, so showing it again
    /// costs nothing and the visualizer never restarts mid-dictation.
    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
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
        panel.ignoresMouseEvents = false

        let view = NSHostingView(rootView: VisualizerPanel(appState: AppState.shared))
        hostingView = view
        panel.contentView = view
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - Self.panelSize.width / 2,
            y: frame.maxY - Self.panelSize.height - 12
        ))
    }
}

// MARK: - Panel

struct VisualizerPanel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            Visualizer(phase: appState.phase, history: appState.levelHistory)
                .frame(height: 34)

            if case .recording = appState.phase {
                Button {
                    appState.stopButtonTapped()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
                .help("Stop recording")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 260, height: 76)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

// MARK: - Visualizer

/// A music-visualizer style level meter.
///
/// While **recording**, each bar is a sample of real microphone amplitude:
/// the newest level enters on the right and history scrolls left, mirrored
/// about the centre line. While **processing** there is no microphone
/// input, so the bars run a travelling sine wave instead — visibly
/// different from recording, which is the point: the two states should
/// never be confusable at a glance.
struct Visualizer: View {
    let phase: DictationPhase
    /// Level history, oldest first, owned by `AppState`.
    let history: [Float]

    var body: some View {
        // TimelineView drives only the processing animation, which is a
        // pure function of time. Recording bars redraw when `history`
        // publishes, so neither path mutates state per frame.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, now: timeline.date)
            }
        }
    }

    private var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let count = max(1, history.count)
        let spacing: CGFloat = 3
        let barWidth = max(1.5, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
        let midY = size.height / 2

        for index in 0..<count {
            let amplitude = isRecording
                ? recordingAmplitude(at: index, count: count)
                : processingAmplitude(at: index, count: count, now: now)

            let barHeight = max(barWidth, amplitude * size.height)
            let x = CGFloat(index) * (barWidth + spacing)
            let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)

            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .color(barColor(at: index, count: count, amplitude: amplitude))
            )
        }
    }

    private func recordingAmplitude(at index: Int, count: Int) -> CGFloat {
        // Taper the oldest samples so history fades out on the left rather
        // than ending in a hard edge.
        let ageFade = 0.35 + 0.65 * (CGFloat(index) / CGFloat(max(1, count - 1)))
        return min(1, CGFloat(history[index]) * ageFade)
    }

    private func processingAmplitude(at index: Int, count: Int, now: Date) -> CGFloat {
        let wavePhase = now.timeIntervalSinceReferenceDate * 6.5
        let position = CGFloat(index) / CGFloat(max(1, count - 1))
        let wave = sin(position * .pi * 2.2 - wavePhase)
        // Envelope keeps the ends short so the wave reads as a pulse
        // travelling through the bars.
        let envelope = sin(position * .pi)
        return 0.08 + 0.42 * envelope * (0.5 + 0.5 * wave)
    }

    private func barColor(at index: Int, count: Int, amplitude: CGFloat) -> Color {
        if isRecording {
            // Newest bars are fully saturated; older history recedes.
            let recency = CGFloat(index) / CGFloat(count - 1)
            return Color.accentColor.opacity(0.35 + 0.65 * recency)
        }
        return Color.accentColor.opacity(0.3 + 0.5 * amplitude)
    }
}
