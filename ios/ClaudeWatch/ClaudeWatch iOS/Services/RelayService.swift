import Foundation
import Combine

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

    // Permission prompt state
    @Published var pendingPermission: PendingPermission? = nil

    struct PendingPermission: Identifiable {
        let id: String // permissionId from bridge
        let toolName: String
        let description: String
        let filePath: String?
        let timestamp: Date = Date()
    }

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

        // Strip ANSI escape codes for display
        let cleaned = text.replacingOccurrences(
            of: "\\x1B\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression
        )

        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let line = TerminalLine(text: cleaned, type: .output)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)

        // Batch terminal updates to the watch (1-second window)
        pendingTerminalLines.append(line)
        scheduleBatchSend()
    }

    private func handlePermissionRequest(_ data: String) {
        guard let json = parseJSON(data) else { return }

        let permissionId = json["permissionId"] as? String ?? UUID().uuidString
        let toolName = json["tool_name"] as? String ?? "Unknown tool"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]

        // Build a human-readable description
        var description = ""
        var filePath: String? = nil

        switch toolName {
        case "Edit":
            filePath = toolInput["file_path"] as? String
            let filename = ((filePath ?? "") as NSString).lastPathComponent
            description = "Edit \(filename)"
        case "Write":
            filePath = toolInput["file_path"] as? String
            let filename = ((filePath ?? "") as NSString).lastPathComponent
            description = "Create/overwrite \(filename)"
        case "Bash":
            let cmd = toolInput["command"] as? String ?? ""
            description = "Run: \(String(cmd.prefix(100)))"
        case "Read":
            filePath = toolInput["file_path"] as? String
            let filename = ((filePath ?? "") as NSString).lastPathComponent
            description = "Read \(filename)"
        default:
            description = toolName
        }

        print("[RelayService] Permission requested: \(toolName) — \(description)")

        // Show interactive prompt in the app
        pendingPermission = PendingPermission(
            id: permissionId,
            toolName: toolName,
            description: description,
            filePath: filePath
        )

        // Add to terminal as well
        let line = TerminalLine(text: "⚠ Permission: \(description)", type: .system)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)

        // Forward to watch
        let request = ApprovalRequest(toolName: toolName, actionSummary: description)
        let message = WatchMessage.approvalRequestMessage(request)
        sessionManager.send(message)

        // Notification if backgrounded
        notificationService.postApprovalNeeded(toolName: toolName, summary: description)
    }

    // MARK: - Permission response

    /// "Yes, allow all" — allow this and add a permission rule so it doesn't ask again this session
    func respondToPermissionAllowAll(permissionId: String) {
        print("[RelayService] Responding to permission \(permissionId): allow (all session)")

        Task {
            do {
                try await bridgeClient.respondToApprovalAllowAll(requestId: permissionId)
                await MainActor.run {
                    let line = TerminalLine(text: "✓ Approved (all session)", type: .output)
                    self.terminalBuffer.append(line)
                    self.recentTerminalLines = self.terminalBuffer.getLast(15)
                    self.pendingPermission = nil
                }
            } catch {
                print("[RelayService] Failed to respond to permission: \(error)")
            }
        }
    }

    func respondToPermission(permissionId: String, allow: Bool) {
        print("[RelayService] Responding to permission \(permissionId): \(allow ? "allow" : "deny")")

        let decision: [String: Any] = [
            "behavior": allow ? "allow" : "deny"
        ]

        Task {
            do {
                try await bridgeClient.respondToApproval(requestId: permissionId, allow: allow)
                await MainActor.run {
                    let line = TerminalLine(
                        text: allow ? "✓ Approved" : "✗ Denied",
                        type: allow ? .output : .error
                    )
                    self.terminalBuffer.append(line)
                    self.recentTerminalLines = self.terminalBuffer.getLast(15)
                    self.pendingPermission = nil
                }
            } catch {
                print("[RelayService] Failed to respond to permission: \(error)")
            }
        }
    }

    private func handleSessionEvent(_ data: String) {
        guard let json = parseJSON(data),
              let state = json["state"] as? String else { return }

        switch state {
        case "running":
            sessionStartDate = Date()
        case "ended":
            stopElapsedTimer()
            notificationService.postTaskComplete()
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

        // Format like a real terminal: show what Claude did and the result
        var lines: [TerminalLine] = []

        switch toolName {
        case "Bash":
            let cmd = toolInput["command"] as? String ?? ""
            lines.append(TerminalLine(text: "$ \(cmd)", type: .command))
            if let output = toolOutput, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Show first ~10 lines of output
                let outputLines = output.components(separatedBy: "\n")
                for line in outputLines.prefix(10) {
                    let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        lines.append(TerminalLine(text: cleaned, type: .output))
                    }
                }
                if outputLines.count > 10 {
                    lines.append(TerminalLine(text: "  ... (\(outputLines.count - 10) more lines)", type: .system))
                }
            }

        case "Read":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "Read \(filename)", type: .system))

        case "Write":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "Write \(filename)", type: .system))

        case "Edit":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            let oldStr = toolInput["old_string"] as? String ?? ""
            let newStr = toolInput["new_string"] as? String ?? ""
            lines.append(TerminalLine(text: "Edit \(filename)", type: .system))
            if !oldStr.isEmpty {
                let preview = oldStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  - \(String(preview.prefix(60)))", type: .error))
            }
            if !newStr.isEmpty {
                let preview = newStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  + \(String(preview.prefix(60)))", type: .output))
            }

        case "Grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "grep \"\(pattern)\"", type: .command))
            if let output = toolOutput, !output.isEmpty {
                let resultLines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                lines.append(TerminalLine(text: "  \(resultLines.count) matches", type: .system))
            }

        case "Glob":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "find \"\(pattern)\"", type: .command))

        default:
            lines.append(TerminalLine(text: "[\(toolName)]", type: .system))
            if let output = toolOutput {
                let preview = String(output.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    lines.append(TerminalLine(text: preview, type: .output))
                }
            }
        }

        for line in lines {
            terminalBuffer.append(line)
            pendingTerminalLines.append(line)
        }
        recentTerminalLines = terminalBuffer.getLast(10)
        scheduleBatchSend()
    }

    private func handleTaskComplete(_ data: String) {
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
