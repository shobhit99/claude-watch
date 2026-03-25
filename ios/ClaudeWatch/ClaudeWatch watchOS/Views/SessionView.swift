import SwiftUI

// MARK: - SessionView

/// The main screen: shows terminal output and captures commands.
struct SessionView: View {
    @EnvironmentObject private var session: WatchSessionManager

    @State private var showVoiceInput = false
    @State private var showTextInput = false
    @State private var showTaskComplete = false
    @State private var thinkingElapsed: TimeInterval = 0
    @State private var showCancelThinking = false

    // Thinking cursor blink
    @State private var cursorVisible = true
    private let cursorTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    // 30s timeout for thinking state
    private let thinkingTimeoutTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.Background.primary.ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: Top Bar
                topBar

                // MARK: Connection Banners
                connectionBanner

                // MARK: Terminal Output
                terminalArea

                // MARK: Bottom Input Bar
                bottomBar
            }

            // MARK: Disconnected Overlay
            if session.sessionState.connection == .disconnected {
                disconnectedOverlay
            }

            // MARK: Task Complete Overlay
            if showTaskComplete, let summary = session.taskCompleteSummary {
                taskCompleteOverlay(summary: summary)
            }
        }
        .sheet(item: $session.pendingApproval) { request in
            ApprovalView(request: request)
        }
        .fullScreenCover(isPresented: $showVoiceInput) {
            VoiceInputView()
        }
        .onChange(of: session.taskCompleteSummary) { newValue in
            if newValue != nil {
                showTaskComplete = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.easeOut(duration: 0.5)) {
                        showTaskComplete = false
                    }
                    session.taskCompleteSummary = nil
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            // Claude mascot placeholder
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.Text.primary)
                .frame(width: 32, height: 32)
                .overlay(
                    Text("C")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                )
                .opacity(connectionMascotOpacity)

            Text("Claude")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.Text.primary)

            Spacer()

            connectionIndicator
        }
        .frame(height: 44)
        .padding(.horizontal, 8)
    }

    private var connectionMascotOpacity: Double {
        switch session.sessionState.connection {
        case .disconnected: return 0.4
        default: return 1.0
        }
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch session.sessionState.connection {
        case .connected where session.isStreaming:
            Circle()
                .fill(Theme.Accent.success)
                .frame(width: 8, height: 8)
                .modifier(PulseModifier())
        case .connected:
            Circle()
                .fill(Theme.Accent.success)
                .frame(width: 8, height: 8)
        case .connecting:
            Circle()
                .fill(Theme.Text.secondary)
                .frame(width: 8, height: 8)
                .modifier(PulseModifier())
        case .disconnected:
            Circle()
                .fill(Theme.Accent.error)
                .frame(width: 8, height: 8)
        case .iPhoneUnreachable:
            Circle()
                .fill(Theme.Accent.approval)
                .frame(width: 8, height: 8)
        }
    }

    // MARK: - Connection Banners

    @ViewBuilder
    private var connectionBanner: some View {
        if session.sessionState.connection == .iPhoneUnreachable {
            HStack(spacing: 4) {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 11))
                Text("Open iPhone app for live commands")
                    .font(.system(size: 11))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(Theme.Accent.approval)
        }
    }

    // MARK: - Terminal Area

    private var terminalArea: some View {
        Group {
            if session.terminalLines.isEmpty && session.sessionState.activity == .idle {
                emptyState
            } else {
                terminalScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.Text.primary.opacity(0.15))
                .frame(width: 48, height: 48)
                .overlay(
                    Text("C")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.Text.primary.opacity(0.5))
                )

            Text("No active session.\nTap mic to start.")
                .font(.system(size: 13))
                .foregroundColor(Theme.Text.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
    }

    private var terminalScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(session.terminalLines) { line in
                        terminalLineView(line)
                            .id(line.id)
                    }

                    // Thinking cursor
                    if isThinking {
                        thinkingView
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(height: 280)
            .onChange(of: session.terminalLines.count) { _ in
                if let lastLine = session.terminalLines.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastLine.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func terminalLineView(_ line: TerminalLine) -> some View {
        switch line.type {
        case .output:
            Text(line.text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Theme.Text.primary)
        case .command:
            Text(line.text)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Text.primary)
        case .system:
            Text(line.text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Theme.Text.secondary)
        case .thinking:
            EmptyView() // Handled separately below the list
        case .error:
            Text(line.text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Theme.Accent.error)
        }
    }

    private var isThinking: Bool {
        session.sessionState.activity == .running &&
        session.terminalLines.last?.type == .thinking
    }

    private var thinkingView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cursorVisible ? "\u{2588}" : " ")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Theme.Text.primary)
                .onReceive(cursorTimer) { _ in
                    cursorVisible.toggle()
                }

            if showCancelThinking {
                HStack(spacing: 4) {
                    Text("Still working...")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Text.secondary)

                    Button("Cancel") {
                        cancelThinking()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Accent.error)
                }
            }
        }
        .onReceive(thinkingTimeoutTimer) { _ in
            if isThinking {
                thinkingElapsed += 1
                if thinkingElapsed >= 30 {
                    showCancelThinking = true
                }
            } else {
                thinkingElapsed = 0
                showCancelThinking = false
            }
        }
    }

    private func cancelThinking() {
        // Remove thinking line
        session.terminalLines.removeAll { $0.type == .thinking }
        session.appendLine(TerminalLine(text: "[Cancelled]", type: .system))
        thinkingElapsed = 0
        showCancelThinking = false
    }

    // MARK: - Disconnected Overlay

    private var disconnectedOverlay: some View {
        ZStack {
            Theme.Background.primary.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.Text.dimmed.opacity(0.3))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Text("C")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(Theme.Text.dimmed)
                        )

                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.Accent.error)
                        .offset(x: 18, y: -18)
                }

                Text("Disconnected")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.Text.dimmed)
            }
        }
    }

    // MARK: - Task Complete Overlay

    private func taskCompleteOverlay(summary: String) -> some View {
        VStack(spacing: 8) {
            Text("Done")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.Accent.success)

            Text(summary)
                .font(.system(size: 13))
                .foregroundColor(Theme.Text.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.Background.overlay)
        )
        .transition(.opacity)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Spacer()

            // Text input button
            Button {
                showTextInput = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.Text.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            // Mic button
            Button {
                showVoiceInput = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Theme.Text.primary)
                        .frame(width: 56, height: 56)

                    if session.sessionState.connection == .iPhoneUnreachable {
                        // Show hourglass badge
                        ZStack {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.black)

                            Image(systemName: "hourglass")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.Accent.approval)
                                .offset(x: 12, y: -12)
                        }
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.black)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Pulse Animation Modifier

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Preview

#Preview {
    SessionView()
        .environmentObject(WatchSessionManager.shared)
}
