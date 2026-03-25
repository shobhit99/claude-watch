import SwiftUI

// MARK: - VoiceInputView

/// Full-screen voice capture mode. Records speech, transcribes, previews, and sends.
struct VoiceInputView: View {
    @EnvironmentObject private var session: WatchSessionManager
    @StateObject private var speechService = SpeechService()
    @Environment(\.dismiss) private var dismiss

    @State private var animationPhase: CGFloat = 0
    private let waveTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    enum InputState {
        case recording
        case transcribing
        case preview
    }

    private var inputState: InputState {
        if speechService.isRecording {
            return .recording
        } else if speechService.transcribedText.isEmpty && !speechService.isRecording {
            // Still processing or just stopped
            if speechService.error != nil {
                return .preview // Show error in preview
            }
            return .transcribing
        } else {
            return .preview
        }
    }

    var body: some View {
        ZStack {
            Theme.Background.capture.ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()

                switch inputState {
                case .recording:
                    recordingView
                case .transcribing:
                    transcribingView
                case .preview:
                    previewView
                }

                Spacer()

                // Cancel is always available
                if inputState == .recording {
                    Button {
                        speechService.stopRecording()
                    } label: {
                        Text("Done")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Theme.Text.primary)
                    }
                    .buttonStyle(.plain)
                } else if inputState != .transcribing {
                    // Preview state has its own buttons
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .onAppear {
            speechService.startRecording()
        }
        .onDisappear {
            if speechService.isRecording {
                speechService.stopRecording()
            }
        }
    }

    // MARK: - Recording View

    private var recordingView: some View {
        VStack(spacing: 16) {
            Text("Listening...")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.Text.primary)

            // Placeholder waveform: 3 horizontal bars with varying heights
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.Text.primary)
                        .frame(width: 6, height: barHeight(for: index))
                        .animation(
                            .easeInOut(duration: 0.3)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15),
                            value: animationPhase
                        )
                }
            }
            .frame(height: 40)
            .onReceive(waveTimer) { _ in
                animationPhase += 1
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 12
        let variation: CGFloat = 20
        let phase = animationPhase + CGFloat(index) * 2
        return base + abs(sin(phase * 0.3)) * variation
    }

    // MARK: - Transcribing View

    private var transcribingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Theme.Text.secondary)

            Text("Transcribing...")
                .font(.system(size: 13))
                .foregroundColor(Theme.Text.secondary)
        }
    }

    // MARK: - Preview View

    private var previewView: some View {
        VStack(spacing: 12) {
            if let error = speechService.error {
                Text(error)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Theme.Accent.error)
                    .multilineTextAlignment(.center)
            } else {
                ScrollView {
                    Text(speechService.transcribedText)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(Theme.Text.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            // Send button
            if speechService.error == nil && !speechService.transcribedText.isEmpty {
                Button {
                    sendCommand()
                } label: {
                    Text("Send")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Theme.Text.primary)
                        )
                }
                .buttonStyle(.plain)
            }

            // Cancel button
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Text.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func sendCommand() {
        let text = speechService.transcribedText
        guard !text.isEmpty else { return }

        HapticManager.commandSent()
        session.sendVoiceCommand(text)
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    VoiceInputView()
        .environmentObject(WatchSessionManager.shared)
}
