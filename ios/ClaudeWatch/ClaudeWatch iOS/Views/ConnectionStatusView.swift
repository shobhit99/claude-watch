import SwiftUI
import UIKit

struct ConnectionStatusView: View {

    @EnvironmentObject private var relayService: RelayService
    @EnvironmentObject private var sessionManager: WatchSessionManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false
    @State private var activeSessionIndex = 0

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
                        ZStack(alignment: .bottomLeading) {
                            sessionPager

                            // Floating clear button — outside TabView to avoid swipe conflicts
                            Button {
                                let sessionId = relayService.sessions.indices.contains(activeSessionIndex)
                                    ? relayService.sessions[activeSessionIndex].id
                                    : nil
                                relayService.clearTerminal(sessionId: sessionId)
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.subtleText.opacity(0.4))
                                        .frame(width: 32, height: 32)
                                    Image(systemName: "trash")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white)
                                }
                                .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 26)
                            .padding(.bottom, 16)
                        }
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
                .fill(connectionBadgeColor)
                .frame(width: 6, height: 6)
            Text(connectionBadgeText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(connectionBadgeColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.connectedPillBackground)
        .clipShape(Capsule())
    }

    private var connectionBadgeText: String {
        switch relayService.transportMode {
        case .lan: return "LAN"
        case .remote: return "REMOTE"
        }
    }

    private var connectionBadgeColor: Color {
        switch relayService.transportMode {
        case .lan: return Color.statusGreen
        case .remote: return Color.claudeOrange
        }
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
            ForEach(Array(relayService.sessions.enumerated()), id: \.element.id) { index, _ in
                SessionPageView(sessionIndex: index)
                    .environmentObject(relayService)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: relayService.sessions.count > 1 ? .automatic : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
    }

}

// MARK: - Session Page View

private struct SessionPageView: View {
    let sessionIndex: Int
    @EnvironmentObject private var relayService: RelayService

    @State private var cursorVisible = true
    @State private var promptText = ""
    @FocusState private var isPromptFocused: Bool

    private let cursorTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    private var session: AgentSession {
        guard relayService.sessions.indices.contains(sessionIndex) else {
            return AgentSession(id: "", agent: .claude, cwd: "", folderName: "", activity: .idle)
        }
        return relayService.sessions[sessionIndex]
    }

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
                    relayService.respondToApprovalWithOption(option.label, index: index)
                    promptText = ""
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

            // Text input for custom response
            if approval.question != nil {
                HStack(spacing: 8) {
                    TextField("Type a response...", text: $promptText)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white)
                        .tint(Color.claudeOrange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .focused($isPromptFocused)
                        .onSubmit { submitPromptText() }

                    Button { submitPromptText() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.subtleText
                                : Color.claudeOrange)
                    }
                    .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
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
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(session.terminalLines.suffix(50)) { line in
                        TerminalLineRow(line: line)
                            .id(line.id)
                    }

                    if relayService.isThinking {
                        Text(cursorVisible ? "\u{2588}" : " ")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.claudeOrange)
                            .onReceive(cursorTimer) { _ in cursorVisible.toggle() }
                            .id("thinking-cursor")
                    }
                }
                .padding(12)
            }
            .onChange(of: session.terminalLines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if relayService.isThinking {
                        proxy.scrollTo("thinking-cursor", anchor: .bottom)
                    } else if let last = session.terminalLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func submitPromptText() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        relayService.respondToApprovalWithOption(text, index: -1)
        promptText = ""
        isPromptFocused = false
    }

    private func colorForOption(_ index: Int, total: Int) -> Color {
        if total <= 1 { return Color.statusGreen }
        if index == 0 { return Color.statusGreen }
        if index == total - 1 { return .red }
        return Color.claudeOrange
    }
}

// MARK: - Terminal Line Row (collapsible)

private struct TerminalLineRow: View {
    let line: TerminalLine
    @State private var isExpanded = false

    private let truncateThreshold = 60

    private var isLong: Bool {
        line.text.count > truncateThreshold
    }

    private var displayText: String {
        if isExpanded || !isLong {
            return line.text
        }
        return String(line.text.prefix(truncateThreshold)) + "..."
    }

    private var icon: String? {
        switch line.type {
        case .command: return line.text.hasPrefix("$") ? nil : nil
        case .system:
            if line.text.hasPrefix("Read ")  { return "doc.text" }
            if line.text.hasPrefix("Edit ")  { return "pencil" }
            if line.text.hasPrefix("Write ") { return "doc.badge.plus" }
            return "gearshape"
        default: return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if let icon, line.type == .system {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.subtleText)
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 2)
            }

            Text(displayText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(colorForType)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isLong {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.subtleText.opacity(0.6))
                    .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isLong {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
        }
    }

    private var colorForType: Color {
        switch line.type {
        case .output:
            if line.text.hasPrefix("  + ") { return Color.statusGreen }
            return Color.claudeOrange
        case .command:  return .white
        case .system:   return Color.subtleText
        case .thinking: return Color.claudeOrange.opacity(0.5)
        case .error:    return .red
        }
    }
}

// MARK: - Preview

#Preview {
    ConnectionStatusView()
        .environmentObject(WatchSessionManager.shared)
        .environmentObject(RelayService.shared)
}
