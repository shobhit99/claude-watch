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
        // Discover bridge via Bonjour
        let service = try await discovery.discover()

        // Configure the HTTP client
        bridgeClient.configure(host: service.host, port: service.port)

        // Attempt pairing
        try await bridgeClient.pair(code: code)

        // Success
        machineName = service.machineName
        lastConnected = Date()
        isPaired = true

        UserDefaults.standard.set(service.machineName, forKey: "paired_machine_name")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")

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
        recentTerminalLines = terminalBuffer.getLast(5)

        // Batch terminal updates to the watch (1-second window)
        pendingTerminalLines.append(line)
        scheduleBatchSend()
    }

    private func handlePermissionRequest(_ data: String) {
        guard let json = parseJSON(data) else { return }

        let permissionId = json["permissionId"] as? String ?? UUID().uuidString
        let toolName = json["tool_name"] as? String ?? "Unknown tool"
        let description = json["tool_input"] as? String ?? toolName

        let request = ApprovalRequest(toolName: toolName, actionSummary: description)

        // Forward to watch via sendMessage for immediate delivery
        let message = WatchMessage.approvalRequestMessage(request)
        sessionManager.send(message)

        // Also send a notification if app is backgrounded
        notificationService.postApprovalNeeded(toolName: toolName, summary: description)

        // Store permissionId mapping so we can respond
        UserDefaults.standard.set(permissionId, forKey: "pending_permission_\(request.id.uuidString)")
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
        let line = TerminalLine(text: "[\(toolName) completed]", type: .system)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(5)
    }

    private func handleTaskComplete(_ data: String) {
        let line = TerminalLine(text: "Task completed", type: .system)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(5)
        notificationService.postTaskComplete()
        updateWatchState()
    }

    private func handleError(_ data: String) {
        guard let json = parseJSON(data) else { return }
        let errorMsg = json["error"] as? String ?? "Unknown error"
        let line = TerminalLine(text: errorMsg, type: .error)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(5)
    }

    private func handleStop(_ data: String) {
        let line = TerminalLine(text: "Session stopped", type: .system)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(5)
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
