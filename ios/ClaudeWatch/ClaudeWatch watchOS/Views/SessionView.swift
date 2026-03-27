import SwiftUI

struct SessionView: View {
    let agentSession: AgentSession
    @EnvironmentObject private var session: WatchViewState

    @State private var showVoiceInput = false
    @State private var cursorVisible = true
    private let cursorTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // Top bar — agent icon + folder name
                HStack(spacing: 4) {
                    AgentIcon(agent: agentSession.agent, size: 14)
                    Text(agentSession.folderName.isEmpty ? agentSession.agent.rawValue.capitalized : agentSession.folderName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.Text.primary)
                        .lineLimit(1)
                    Spacer()
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

                // Terminal
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(visibleLines) { line in
                                terminalLine(line)
                                    .id(line.id)
                            }

                            if isThinking {
                                Text(cursorVisible ? "\u{2588}" : " ")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.Text.primary)
                                    .onReceive(cursorTimer) { _ in cursorVisible.toggle() }
                                    .id("cursor")
                            }

                            Spacer().frame(height: 40)
                        }
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: agentSession.terminalLines.count) { _ in
                        withAnimation(.easeOut(duration: 0.1)) {
                            if isThinking {
                                proxy.scrollTo("cursor", anchor: .bottom)
                            } else if let last = visibleLines.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .background(Theme.Background.primary)

            // FAB mic
            Button { showVoiceInput = true } label: {
                ZStack {
                    Circle()
                        .fill(Theme.Text.primary.opacity(0.75))
                        .frame(width: 28, height: 28)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.black)
                }
                .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea(edges: .bottom)
        .sheet(item: $session.pendingApproval) { request in
            ApprovalView(request: request)
        }
        .fullScreenCover(isPresented: $showVoiceInput) {
            VoiceInputView(sessionId: agentSession.id)
        }
    }

    private var visibleLines: [TerminalLine] {
        agentSession.terminalLines
            .filter { !$0.text.isEmpty || $0.type == .thinking }
            .suffix(30)
            .map { $0 }
    }

    @ViewBuilder
    private func terminalLine(_ line: TerminalLine) -> some View {
        Text(line.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(colorFor(line.type))
            .lineLimit(4)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isThinking: Bool {
        agentSession.terminalLines.last?.type == .thinking
    }

    private var statusColor: Color {
        switch agentSession.activity {
        case .running: return Theme.Accent.success
        case .waitingApproval: return Theme.Accent.approval
        case .ended: return Theme.Accent.error
        case .idle: return Theme.Text.secondary
        }
    }

    private func colorFor(_ type: TerminalLine.LineType) -> Color {
        switch type {
        case .output:   return Theme.Text.primary
        case .command:  return .white
        case .system:   return Theme.Text.secondary
        case .thinking: return Theme.Text.primary.opacity(0.5)
        case .error:    return Theme.Accent.error
        }
    }
}

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false
    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
