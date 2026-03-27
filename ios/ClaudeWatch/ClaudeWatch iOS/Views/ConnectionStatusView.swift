import SwiftUI
import UIKit

struct ConnectionStatusView: View {

    @EnvironmentObject private var relayService: RelayService
    @EnvironmentObject private var sessionManager: WatchSessionManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false
    @State private var activeSessionIndex = 0
    @State private var commandText = ""
    @FocusState private var isCommandFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 8)

                    if relayService.sessions.isEmpty {
                        waitingView
                    } else {
                        sessionPager

                        commandInputBar
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Color.subtleText)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(relayService)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            AppLogo(size: 28)

            Text("Agent Watch")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            connectionBadge
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.statusGreen)
                .frame(width: 6, height: 6)
            Text("LAN")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.statusGreen)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.connectedPillBackground)
        .clipShape(Capsule())
    }

    // MARK: - Waiting for sessions

    private var waitingView: some View {
        VStack(spacing: 12) {
            Spacer()
            AppLogo(size: 56)
                .opacity(0.6)
            Text("Waiting for session...")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.subtleText)
            Text("Connected to \(relayService.machineName ?? "Mac")")
                .font(.system(size: 13))
                .foregroundStyle(Color.subtleText.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Session pager

    private var sessionPager: some View {
        TabView(selection: $activeSessionIndex) {
            ForEach(Array(relayService.sessions.enumerated()), id: \.element.id) { index, session in
                SessionPageView(
                    session: session,
                    respondToOption: { label, idx in
                        relayService.respondToApprovalWithOption(label, index: idx)
                    },
                    isThinking: relayService.isThinking
                )
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: relayService.sessions.count > 1 ? .automatic : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
    }

    // MARK: - Command input bar (outside TabView)

    private var commandInputBar: some View {
        HStack(spacing: 8) {
            TextField("Send a command...", text: $commandText)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(.white)
                .tint(Color.claudeOrange)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .focused($isCommandFocused)
                .onSubmit { submitCommand() }

            Button { submitCommand() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.subtleText
                        : Color.claudeOrange)
            }
            .disabled(commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black)
    }

    // MARK: - Helpers

    private func submitCommand() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let sessionId = relayService.sessions.indices.contains(activeSessionIndex)
            ? relayService.sessions[activeSessionIndex].id
            : nil
        relayService.sendCommand(text: text, sessionId: sessionId)
        commandText = ""
    }
}

// MARK: - Session Page View

private struct SessionPageView: View {
    let session: AgentSession
    let respondToOption: (String, Int) -> Void
    let isThinking: Bool

    @State private var cursorVisible = true

    private let cursorTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Session header
            sessionHeader
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            // Approval prompt (if pending for this session)
            if let approval = session.pendingApproval {
                approvalPrompt(approval)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            // Terminal
            terminalView
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Session header

    private var sessionHeader: some View {
        HStack(spacing: 8) {
            AgentIcon(agent: session.agent, size: 18)

            Text(session.folderName.isEmpty ? session.agent.rawValue.capitalized : session.folderName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(session.cwd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.subtleText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusColor: Color {
        switch session.activity {
        case .running: return Color.statusGreen
        case .waitingApproval: return Color.claudeAmber
        case .ended: return .red
        case .idle: return Color.subtleText
        }
    }

    // MARK: - Approval prompt

    private func approvalPrompt(_ approval: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question = approval.question {
                Text(question)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !approval.actionSummary.isEmpty && approval.actionSummary != approval.toolName {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.claudeAmber)
                        .font(.system(size: 14))
                    Text(approval.actionSummary)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
            }

            Divider().background(Color.subtleText.opacity(0.3))

            ForEach(Array(approval.options.enumerated()), id: \.element.id) { index, option in
                Button {
                    respondToOption(option.label, index)
                } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.subtleText)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)

                            if let desc = option.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.subtleText)
                                    .lineLimit(2)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(colorForOption(index, total: approval.options.count).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(colorForOption(index, total: approval.options.count).opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(hex: "1a1a1a"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.claudeAmber.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Terminal

    private var terminalView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(session.terminalLines.suffix(50)) { line in
                        Text(line.text)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(colorForLineType(line.type))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }

                    if isThinking {
                        Text(cursorVisible ? "\u{2588}" : " ")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.claudeOrange)
                            .onReceive(cursorTimer) { _ in cursorVisible.toggle() }
                            .id("thinking-cursor")
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: session.terminalLines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if isThinking {
                        proxy.scrollTo("thinking-cursor", anchor: .bottom)
                    } else if let last = session.terminalLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func colorForLineType(_ type: TerminalLine.LineType) -> Color {
        switch type {
        case .output:   return Color.claudeOrange
        case .command:  return .white
        case .system:   return Color.subtleText
        case .thinking: return Color.claudeOrange.opacity(0.5)
        case .error:    return .red
        }
    }

    private func colorForOption(_ index: Int, total: Int) -> Color {
        if total <= 1 { return Color.statusGreen }
        if index == 0 { return Color.statusGreen }
        if index == total - 1 { return .red }
        return Color.claudeOrange
    }
}

// MARK: - Preview

#Preview {
    ConnectionStatusView()
        .environmentObject(WatchSessionManager.shared)
        .environmentObject(RelayService.shared)
}
