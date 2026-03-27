import Foundation
import Combine
import UIKit

/// Coordinates communication between the bridge server, SSE event stream,
/// and the Apple Watch via WCSession.
///
/// Acts as the central hub: bridge events are received via SSE/polling,
/// parsed, and forwarded to the watch. Commands from the watch are
/// received via WCSession and forwarded to the bridge via HTTP.
@MainActor
final class RelayService: ObservableObject {

    // MARK: - Singleton

    static let shared = RelayService()

    // MARK: - Published state

    @Published private(set) var isPaired: Bool = false
    @Published private(set) var machineName: String?
    @Published private(set) var modelName: String?
    @Published private(set) var workingDirectory: String?
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var recentTerminalLines: [TerminalLine] = []
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastConnected: Date?
    @Published private(set) var isThinking: Bool = false

    // Multi-session
    @Published private(set) var sessions: [AgentSession] = []

    // Permission prompt state (uses shared ApprovalRequest model)
    @Published var pendingApproval: ApprovalRequest? = nil

    // MARK: - Private

    private let bridgeClient = BridgeClient()
    private let sseClient = SSEClient()
    private let discovery = BonjourDiscovery()
    private let notificationService = NotificationService()
    private let sessionManager = WatchSessionManager.shared

    private let terminalBuffer = OutputRingBuffer<TerminalLine>(capacity: 50)
    private var terminalBatchTimer: Timer?
    private var pendingTerminalLines: [TerminalLine] = []

    private var elapsedTimer: Timer?
    private var sessionStartDate: Date?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    private init() {
        isPaired = bridgeClient.isPaired
        setupWatchMessageHandler()
        setupSSEEventHandler()

        if isPaired {
            Task { await reconnect() }
        }
    }

    // MARK: - Pairing

    /// Discovers the bridge on LAN and pairs with the given code.
    func pair(code: String) async throws {
        print("[RelayService] Starting pair with code: \(code)")

        // Discover bridge via Bonjour (or localhost fallback)
        let service: BonjourDiscovery.DiscoveredService
        do {
            service = try await discovery.discover()
            print("[RelayService] Discovered bridge at \(service.host):\(service.port)")
        } catch {
            print("[RelayService] Discovery failed: \(error)")
            throw error
        }

        // Configure the HTTP client
        bridgeClient.configure(host: service.host, port: service.port)

        // Attempt pairing
        do {
            try await bridgeClient.pair(code: code)
            print("[RelayService] Pairing successful!")
        } catch {
            print("[RelayService] Pairing failed: \(error)")
            throw error
        }

        // Success
        machineName = service.machineName
        lastConnected = Date()
        isPaired = true
        connectionState = .connected

        UserDefaults.standard.set(service.host, forKey: "bridge_host")
        UserDefaults.standard.set(Int(service.port), forKey: "bridge_port")
        UserDefaults.standard.set(service.machineName, forKey: "paired_machine_name")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")

        print("[RelayService] isPaired = true, starting event stream")

        // Start SSE connection
        startEventStream()
        startElapsedTimer()

        // Notify watch of connection
        updateWatchState()
    }

    /// Removes pairing and disconnects.
    func unpair() {
        sseClient.disconnect()
        bridgeClient.clearCredentials()
        stopElapsedTimer()
        terminalBatchTimer?.invalidate()
        terminalBatchTimer = nil

        isPaired = false
        machineName = nil
        modelName = nil
        workingDirectory = nil
        elapsedSeconds = 0
        recentTerminalLines = []
        connectionState = .disconnected

        UserDefaults.standard.removeObject(forKey: "paired_machine_name")
        UserDefaults.standard.removeObject(forKey: "last_connected")

        // Notify watch
        let state = SessionState.disconnected
        sessionManager.updateApplicationContext(with: state)
    }

    // MARK: - Reconnection

    private func reconnect() async {
        guard bridgeClient.isPaired else { return }

        machineName = UserDefaults.standard.string(forKey: "paired_machine_name")
        if let ts = UserDefaults.standard.object(forKey: "last_connected") as? TimeInterval {
            lastConnected = Date(timeIntervalSince1970: ts)
        }

        connectionState = .connecting
        startEventStream()
        startElapsedTimer()
    }

    // MARK: - SSE

    private func startEventStream() {
        guard let baseURL = bridgeClient.baseURL, let token = bridgeClient.token else { return }
        sseClient.connect(baseURL: baseURL, token: token)
    }

    private func setupSSEEventHandler() {
        sseClient.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleBridgeEvent(event)
            }
        }

        sseClient.onStateChange = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .connected:
                    self?.connectionState = .connected
                    self?.lastConnected = Date()
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")
                    self?.updateWatchState()
                case .connecting:
                    self?.connectionState = .connecting
                case .disconnected:
                    self?.connectionState = .disconnected
                    self?.updateWatchState()
                case .polling:
                    // Still considered connected, just degraded
                    break
                }
            }
        }
    }

    private func handleBridgeEvent(_ event: SSEClient.SSEEvent) {
        guard let eventType = event.event else { return }
        let data = event.data

        switch eventType {
        case "pty-output":
            handlePtyOutput(data)

        case "permission-request":
            handlePermissionRequest(data)

        case "session":
            handleSessionEvent(data)

        case "tool-output":
            handleToolOutput(data)

        case "task-complete":
            handleTaskComplete(data)

        case "error":
            handleError(data)

        case "stop":
            handleStop(data)

        case "poll-status":
            // Polling fallback -- just keep alive
            break

        default:
            break
        }
    }

    // MARK: - Event handlers

    private func handlePtyOutput(_ data: String) {
        guard let json = parseJSON(data),
              let text = json["text"] as? String else { return }
        let sessionId = json["sessionId"] as? String

        // Strip ANSI escape codes for display
        let cleaned = text.replacingOccurrences(
            of: "\\x1B\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression
        )

        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let line = TerminalLine(text: cleaned, type: .output, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSession(line, sessionId: sessionId)

        // Batch terminal updates to the watch (1-second window)
        pendingTerminalLines.append(line)
        scheduleBatchSend()
    }

    private func handlePermissionRequest(_ data: String) {
        guard let json = parseJSON(data) else { return }

        let permissionId = json["permissionId"] as? String ?? UUID().uuidString
        let toolName = json["tool_name"] as? String ?? "Unknown"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let sessionId = json["sessionId"] as? String

        var question: String? = nil
        var desc = toolName
        var options: [ApprovalRequest.OptionItem] = []

        // Parse questions/options (Codex format with questions array)
        if let questions = toolInput["questions"] as? [[String: Any]],
           let firstQ = questions.first {
            question = firstQ["question"] as? String
            desc = toolInput["command"] as? String
                ?? firstQ["header"] as? String
                ?? toolName
            if let opts = firstQ["options"] as? [[String: Any]] {
                options = opts.map { opt in
                    ApprovalRequest.OptionItem(
                        label: opt["label"] as? String ?? "",
                        description: opt["description"] as? String
                    )
                }
            }
        } else if let path = toolInput["file_path"] as? String {
            let filename = (path as NSString).lastPathComponent
            desc = "\(toolName) \(filename)"
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "Yes, allow all"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        } else if let cmd = toolInput["command"] as? String {
            desc = "Run: \(String(cmd.prefix(100)))"
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "Yes, allow all"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        } else {
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        }

        print("[RelayService] Permission requested: \(toolName) — \(desc)")

        let approval = ApprovalRequest(
            permissionId: permissionId,
            toolName: toolName,
            actionSummary: desc,
            question: question,
            options: options
        )

        pendingApproval = approval

        // Track on specific session
        if let sid = sessionId, let idx = sessions.firstIndex(where: { $0.id == sid }) {
            sessions[idx].pendingApproval = approval
            sessions[idx].activity = .waitingApproval
        }

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

        // Add to terminal
        let line = TerminalLine(text: "⚠ Permission: \(desc)", type: .system, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSession(line, sessionId: sessionId)

        // Forward to watch
        let watchRequest = ApprovalRequest(toolName: toolName, actionSummary: desc, question: question, options: options)
        let message = WatchMessage.approvalRequestMessage(watchRequest)
        sessionManager.send(message)

        // Notification if backgrounded
        notificationService.postApprovalNeeded(toolName: toolName, summary: desc)
    }

    // MARK: - Permission response

    /// Respond to approval with a selected option (dynamic options from server).
    func respondToApprovalWithOption(_ optionLabel: String, index: Int) {
        guard let approval = pendingApproval else { return }
        let permissionId = approval.permissionId ?? ""

        let isLast = index == approval.options.count - 1
        UIImpactFeedbackGenerator(style: isLast ? .heavy : .medium).impactOccurred()

        if approval.question != nil {
            // AskUserQuestion: send the option label
            Task {
                try? await bridgeClient.respondToApprovalWithOption(
                    requestId: permissionId, optionLabel: optionLabel, index: index
                )
            }
        } else {
            // Standard permission: first = allow, last = deny, middle = allow all
            if optionLabel.lowercased().contains("allow all") || optionLabel.lowercased().contains("don't ask") {
                Task { try? await bridgeClient.respondToApprovalAllowAll(requestId: permissionId) }
            } else {
                let approved = !isLast
                Task { try? await bridgeClient.respondToApproval(requestId: permissionId, allow: approved) }
            }
        }

        let line = TerminalLine(text: "→ \(optionLabel)", type: isLast ? .error : .output)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)

        clearPendingApproval(for: approval)
    }

    // MARK: - Send command

    /// Sends a text command to the bridge (iOS equivalent of watchOS voice input).
    func sendCommand(text: String, sessionId: String? = nil) {
        let sid = sessionId ?? sessions.first(where: { $0.activity == .running })?.id

        // Show in terminal
        let cmdLine = TerminalLine(text: "> \(text)", type: .command, sessionId: sid)
        terminalBuffer.append(cmdLine)
        appendToSession(cmdLine, sessionId: sid)
        recentTerminalLines = terminalBuffer.getLast(15)

        isThinking = true

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        Task {
            try? await bridgeClient.sendCommand(text: text + "\n", sessionId: sid)
        }
    }

    // MARK: - Helpers (approval)

    private func clearPendingApproval(for approval: ApprovalRequest) {
        pendingApproval = nil
        for idx in sessions.indices {
            if sessions[idx].pendingApproval?.permissionId == approval.permissionId {
                sessions[idx].pendingApproval = nil
                if sessions[idx].activity == .waitingApproval {
                    sessions[idx].activity = .running
                }
            }
        }
    }

    private func appendToSession(_ line: TerminalLine, sessionId: String?) {
        guard let sid = sessionId,
              let idx = sessions.firstIndex(where: { $0.id == sid }) else { return }
        sessions[idx].terminalLines.append(line)
        if sessions[idx].terminalLines.count > 200 {
            sessions[idx].terminalLines.removeFirst(sessions[idx].terminalLines.count - 200)
        }
    }

    private func handleSessionEvent(_ data: String) {
        guard let json = parseJSON(data),
              let state = json["state"] as? String else { return }

        let sessionId = json["sessionId"] as? String
        let agent = json["agent"] as? String
        let cwd = json["cwd"] as? String ?? ""
        let folderName = json["folderName"] as? String ?? ""

        switch state {
        case "running":
            sessionStartDate = Date()
            if let sid = sessionId {
                if let idx = sessions.firstIndex(where: { $0.id == sid }) {
                    sessions[idx].activity = .running
                } else {
                    let agentType = AgentType(rawValue: agent ?? "claude") ?? .claude
                    sessions.append(AgentSession(
                        id: sid, agent: agentType, cwd: cwd,
                        folderName: folderName, activity: .running
                    ))
                }
            }
        case "ended":
            isThinking = false
            stopElapsedTimer()
            notificationService.postTaskComplete()
            if let sid = sessionId, let idx = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[idx].activity = .ended
            }
        case "connected":
            connectionState = .connected
        default:
            break
        }

        updateWatchState()
    }

    private func handleToolOutput(_ data: String) {
        guard let json = parseJSON(data) else { return }
        let toolName = json["tool_name"] as? String ?? "tool"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let toolOutput = json["tool_output"] as? String
        let sessionId = json["sessionId"] as? String
        let source = json["source"] as? String ?? "claude"
        let prefix = source == "codex" ? "[codex] " : ""

        // Format like a real terminal: show what Claude did and the result
        var lines: [TerminalLine] = []

        switch toolName {
        case "Bash":
            let cmd = toolInput["command"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)$ \(cmd)", type: .command, sessionId: sessionId))
            if let output = toolOutput, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let outputLines = output.components(separatedBy: "\n")
                for line in outputLines.prefix(10) {
                    let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        lines.append(TerminalLine(text: cleaned, type: .output, sessionId: sessionId))
                    }
                }
                if outputLines.count > 10 {
                    lines.append(TerminalLine(text: "  ... (\(outputLines.count - 10) more lines)", type: .system, sessionId: sessionId))
                }
            }

        case "Read":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "\(prefix)Read \(filename)", type: .system, sessionId: sessionId))

        case "Write":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "\(prefix)Write \(filename)", type: .system, sessionId: sessionId))

        case "Edit":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            let oldStr = toolInput["old_string"] as? String ?? ""
            let newStr = toolInput["new_string"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)Edit \(filename)", type: .system, sessionId: sessionId))
            if !oldStr.isEmpty {
                let preview = oldStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  - \(String(preview.prefix(60)))", type: .error, sessionId: sessionId))
            }
            if !newStr.isEmpty {
                let preview = newStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  + \(String(preview.prefix(60)))", type: .output, sessionId: sessionId))
            }

        case "Grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)grep \"\(pattern)\"", type: .command, sessionId: sessionId))
            if let output = toolOutput, !output.isEmpty {
                let resultLines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                lines.append(TerminalLine(text: "  \(resultLines.count) matches", type: .system, sessionId: sessionId))
            }

        case "Glob":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)find \"\(pattern)\"", type: .command, sessionId: sessionId))

        case "CodexMessage":
            if let output = toolOutput {
                lines.append(TerminalLine(text: "\(prefix)\(String(output.prefix(100)))", type: .output, sessionId: sessionId))
            }

        default:
            lines.append(TerminalLine(text: "\(prefix)[\(toolName)]", type: .system, sessionId: sessionId))
            if let output = toolOutput {
                let preview = String(output.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    lines.append(TerminalLine(text: preview, type: .output, sessionId: sessionId))
                }
            }
        }

        for line in lines {
            terminalBuffer.append(line)
            pendingTerminalLines.append(line)
            appendToSession(line, sessionId: sessionId)
        }

        // Mark as thinking (cursor will be shown in the view)
        isThinking = true

        recentTerminalLines = terminalBuffer.getLast(10)
        scheduleBatchSend()
    }

    private func handleTaskComplete(_ data: String) {
        isThinking = false
        let line = TerminalLine(text: "Task completed", type: .system)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        notificationService.postTaskComplete()
        updateWatchState()
    }

    private func handleError(_ data: String) {
        guard let json = parseJSON(data) else { return }
        let errorMsg = json["error"] as? String ?? "Unknown error"
        let line = TerminalLine(text: errorMsg, type: .error)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
    }

    private func handleStop(_ data: String) {
        isThinking = false
        let line = TerminalLine(text: "Session stopped", type: .system)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        updateWatchState()
    }

    // MARK: - Watch communication

    private func setupWatchMessageHandler() {
        sessionManager.onMessageReceived = { [weak self] message in
            Task { @MainActor in
                self?.handleWatchMessage(message)
            }
        }
    }

    private func handleWatchMessage(_ message: WatchMessage) {
        switch message {
        case .voiceCommand(let cmd):
            // Forward voice command to bridge as PTY input
            Task {
                try? await bridgeClient.sendCommand(text: cmd.transcribedText + "\n")
            }

        case .approvalResponse(let response):
            // Forward approval response to bridge
            let key = "pending_permission_\(response.requestId.uuidString)"
            if let permissionId = UserDefaults.standard.string(forKey: key) {
                Task {
                    try? await bridgeClient.respondToApproval(
                        requestId: permissionId,
                        allow: response.approved
                    )
                }
                UserDefaults.standard.removeObject(forKey: key)
            }

        default:
            break
        }
    }

    private func updateWatchState() {
        let state = SessionState(
            connection: connectionState,
            activity: currentActivity,
            machineName: machineName,
            modelName: modelName,
            workingDirectory: workingDirectory,
            elapsedSeconds: elapsedSeconds,
            filesChanged: 0,
            linesAdded: 0,
            transportMode: .lan
        )

        sessionManager.updateApplicationContext(with: state)
    }

    private var currentActivity: SessionActivity {
        switch connectionState {
        case .connected: return .running
        case .connecting: return .idle
        case .disconnected: return .ended
        case .iPhoneUnreachable: return .idle
        }
    }

    // MARK: - Terminal batching

    private func scheduleBatchSend() {
        guard terminalBatchTimer == nil else { return }

        terminalBatchTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.flushTerminalBatch()
            }
        }
    }

    private func flushTerminalBatch() {
        terminalBatchTimer = nil

        guard !pendingTerminalLines.isEmpty else { return }

        let lines = pendingTerminalLines
        pendingTerminalLines = []

        let update = WatchMessage.TerminalUpdate(lines: lines)
        let message = WatchMessage.terminalUpdate(update)
        sessionManager.send(message)
    }

    // MARK: - Elapsed time

    private func startElapsedTimer() {
        sessionStartDate = sessionStartDate ?? Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.sessionStartDate else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - JSON helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
