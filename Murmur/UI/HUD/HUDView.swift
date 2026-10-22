import SwiftUI

struct HUDView: View {
    let dictation: DictationController
    let model: HUDModel
    let dismiss: () -> Void
    let showModeMenu: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background {
                    VisualEffectBackground()
                        .clipShape(Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                }
                .padding(.bottom, 14)
                .animation(.snappy(duration: 0.2), value: stateKey)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private var stateKey: String {
        if dictation.isRecording { return "recording" }
        if let message = model.message { return message.id.uuidString }
        return dictation.pendingJobs > 0 ? "processing" : "idle"
    }

    @ViewBuilder
    private var content: some View {
        if dictation.isRecording {
            RecordingContent(dictation: dictation, showModeMenu: showModeMenu)
        } else if let message = model.message {
            MessageContent(message: message, dismiss: dismiss)
        } else if dictation.pendingJobs > 0 {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(dictation.processingLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(height: 22)
        }
    }
}

struct RecordingContent: View {
    let dictation: DictationController
    let showModeMenu: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PulsingDot()
            Waveform(levels: dictation.levels)
                .frame(width: 112, height: 22)
            if let start = dictation.recordingStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Self.elapsed(since: start, now: context.date))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            // Click to switch the Mode while still recording.
            Button(action: showModeMenu) {
                HStack(spacing: 4) {
                    Text(dictation.recordingMode.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 8)
                .padding(.trailing, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .help("Switch Mode")
        }
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MessageContent: View {
    let message: HUDMessage
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            // One line when it fits; otherwise wrap at a comfortable width.
            ViewThatFits(in: .horizontal) {
                texts.fixedSize()
                texts.frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }

            ForEach(message.actions) { action in
                Button(action.title) { action.perform() }
                    .buttonStyle(HUDButtonStyle(isPrimary: action.isPrimary))
            }
            if !message.actions.isEmpty {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(message.title)
                .font(.system(size: 13, weight: .semibold))
            if let detail = message.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var symbol: String {
        switch message.style {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch message.style {
        case .info: .secondary
        case .warning: .yellow
        case .error: .red
        }
    }
}

private struct HUDButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isPrimary ? Color.accentColor : .white.opacity(0.16), in: Capsule())
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 9, height: 9)
            .shadow(color: .red.opacity(0.7), radius: pulsing ? 4 : 1)
            .opacity(pulsing ? 1 : 0.65)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulsing = true }
            }
    }
}

/// Recent input levels as rounded bars, newest on the right.
struct Waveform: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let spacing: CGFloat = 2
            let barWidth = max(1.5, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            for (index, level) in levels.enumerated() {
                let height = max(2.5, CGFloat(level) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + spacing),
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white.opacity(0.9)))
            }
        }
    }
}

/// Real behind-window blur (SwiftUI materials don't blur through a transparent panel).
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
