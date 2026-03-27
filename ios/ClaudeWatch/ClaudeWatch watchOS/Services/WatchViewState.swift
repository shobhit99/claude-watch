import SwiftUI
import WatchConnectivity

class WatchViewState: ObservableObject {
    static let shared = WatchViewState()

    @Published var isPaired: Bool = false
    @Published var sessionState: SessionState = .disconnected
    @Published var terminalLines: [TerminalLine] = [] // Legacy: flat view of all output
    @Published var pendingApproval: ApprovalRequest? = nil
    @Published var isStreaming: Bool = false
    @Published var taskCompleteSummary: String? = nil
    @Published var isReachable: Bool = false

    // Multi-session
    @Published var sessions: [AgentSession] = []
    @Published var activeSessionIndex: Int = 0

    var activeSession: AgentSession? {
        guard sessions.indices.contains(activeSessionIndex) else { return nil }
        return sessions[activeSessionIndex]
    }

    private let bridge = WatchBridgeClient.shared
    private let maxLines = 200
    private var pollTimer: Timer?
    private var lastEventId: Int = 0
    private var sseTask: URLSessionDataTask?

    private init() {
        if bridge.isPaired {
            Task {
                let reachable = await verifyBridge()
                await MainActor.run {
                    if reachable {
                        isPaired = true
                        startEventStream()
                    } else {
                        bridge.unpair()
                        isPaired = false
                    }
                }
            }
        }
    }

    private func verifyBridge() async -> Bool {
        guard let baseURL = bridge.baseURL, let token = bridge.token else { return false }
        let url = baseURL.appendingPathComponent("status")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Terminal (legacy flat + per-session)

    func appendLine(_ line: TerminalLine, sessionId: String? = nil) {
        DispatchQueue.main.async {
            // Append to legacy flat list
            self.terminalLines.append(line)
            if self.terminalLines.count > self.maxLines {
                self.terminalLines.removeFirst(self.terminalLines.count - self.maxLines)
            }

            // Append to the specific session
            if let sid = sessionId, let idx = self.sessionIndex(for: sid) {
                self.sessions[idx].terminalLines.append(line)
                if self.sessions[idx].terminalLines.count > self.maxLines {
                    self.sessions[idx].terminalLines.removeFirst(
                        self.sessions[idx].terminalLines.count - self.maxLines
                    )
                }
            }
        }
    }

    // MARK: - Session lookup

    private func sessionIndex(for id: String) -> Int? {
        sessions.firstIndex(where: { $0.id == id })
    }

    // MARK: - Event stream (SSE from bridge)

    func startEventStream() {
        guard let baseURL = bridge.baseURL, let token = bridge.token else { return }

        let url = baseURL.appendingPathComponent("events")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if lastEventId > 0 {
            request.setValue("\(lastEventId)", forHTTPHeaderField: "Last-Event-ID")
        }
        request.timeoutInterval = 300

        let session = URLSession(configuration: .default, delegate: SSEDelegate(owner: self), delegateQueue: nil)
        sseTask = session.dataTask(with: request)
        sseTask?.resume()

        DispatchQueue.main.async {
            self.sessionState.connection = .connected
            self.isReachable = true
        }

        print("[WatchViewState] SSE stream started")
    }

    func stopEventStream() {
        sseTask?.cancel()
        sseTask = nil
    }

    // MARK: - SSE parsing

    func handleSSEData(_ text: String) {
        let blocks = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }

        for block in blocks {
            var eventType: String?
            var eventData: String?
            var eventId: Int?

            for line in block.components(separatedBy: "\n") {
                if line.hasPrefix("id: ") {
                    eventId = Int(line.dropFirst(4))
                } else if line.hasPrefix("event: ") {
                    eventType = String(line.dropFirst(7))
                } else if line.hasPrefix("data: ") {
                    let dataLine = String(line.dropFirst(6))
                    if eventData == nil {
                        eventData = dataLine
                    } else {
                        eventData! += "\n" + dataLine
                    }
                } else if line.hasPrefix(":") {
                    continue
                }
            }

            if let id = eventId { lastEventId = id }
            guard let type = eventType, let data = eventData else { continue }

            DispatchQueue.main.async {
                self.processEvent(type: type, data: data)
            }
        }
    }

    private func processEvent(type: String, data: String) {
        guard let json = parseJSON(data) else { return }
        let sessionId = json["sessionId"] as? String

        switch type {
        case "tool-output":
            handleToolOutput(json, sessionId: sessionId)

        case "permission-request":
            handlePermissionRequest(json, sessionId: sessionId)

        case "stop":
            appendLine(TerminalLine(text: "— stopped —", type: .system), sessionId: sessionId)
            isStreaming = false
            if let sid = sessionId, let idx = sessionIndex(for: sid) {
                sessions[idx].activity = .idle
            }

        case "session":
            handleSessionEvent(json, sessionId: sessionId)

        case "pty-output":
            if let text = json["text"] as? String {
                let cleaned = text.replacingOccurrences(
                    of: "\\x1B\\[[0-9;]*[a-zA-Z]",
                    with: "",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    appendLine(TerminalLine(text: String(cleaned.prefix(80)), type: .output), sessionId: sessionId)
                }
            }

        case "task-complete":
            let summary = json["summary"] as? String
            taskCompleteSummary = summary
            HapticManager.taskComplete()

        default:
            break
        }
    }

    // MARK: - Event handlers

    private func handleToolOutput(_ json: [String: Any], sessionId: String?) {
        let toolName = json["tool_name"] as? String ?? "tool"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let source = json["source"] as? String ?? "claude"
        let toolOutput = json["tool_output"] as? String
        let prefix = source == "codex" ? "[codex] " : ""

        switch toolName {
        case "Bash":
            let cmd = toolInput["command"] as? String ?? ""
            appendLine(TerminalLine(text: "\(prefix)$ \(cmd)", type: .command), sessionId: sessionId)
            if let output = toolOutput, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for line in output.components(separatedBy: "\n").prefix(5) {
                    let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        appendLine(TerminalLine(text: cleaned, type: .output), sessionId: sessionId)
                    }
                }
            }
        case "Read":
            let path = toolInput["file_path"] as? String ?? ""
            appendLine(TerminalLine(text: "\(prefix)Read \((path as NSString).lastPathComponent)", type: .system), sessionId: sessionId)
        case "Edit":
            let path = toolInput["file_path"] as? String ?? ""
            appendLine(TerminalLine(text: "\(prefix)Edit \((path as NSString).lastPathComponent)", type: .system), sessionId: sessionId)
        case "Write":
            let path = toolInput["file_path"] as? String ?? ""
            appendLine(TerminalLine(text: "\(prefix)Write \((path as NSString).lastPathComponent)", type: .system), sessionId: sessionId)
        case "Grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            appendLine(TerminalLine(text: "\(prefix)grep \"\(pattern)\"", type: .command), sessionId: sessionId)
        case "CodexMessage":
            if let output = toolOutput {
                appendLine(TerminalLine(text: "\(prefix)\(String(output.prefix(80)))", type: .output), sessionId: sessionId)
            }
        default:
            appendLine(TerminalLine(text: "\(prefix)[\(toolName)]", type: .system), sessionId: sessionId)
        }
        isStreaming = true
    }

    private func handlePermissionRequest(_ json: [String: Any], sessionId: String?) {
        let permissionId = json["permissionId"] as? String ?? UUID().uuidString
        let toolName = json["tool_name"] as? String ?? "Unknown"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]

        var question: String? = nil
        var desc = toolName
        var options: [ApprovalRequest.OptionItem] = []

        if let questions = toolInput["questions"] as? [[String: Any]],
           let firstQ = questions.first {
            question = firstQ["question"] as? String
            desc = firstQ["header"] as? String ?? toolName
            if let opts = firstQ["options"] as? [[String: Any]] {
                options = opts.map { opt in
                    ApprovalRequest.OptionItem(
                        label: opt["label"] as? String ?? "",
                        description: opt["description"] as? String
                    )
                }
            }
        } else if let path = toolInput["file_path"] as? String {
            desc = "\(toolName) \((path as NSString).lastPathComponent)"
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "Yes, allow all"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        } else if let cmd = toolInput["command"] as? String {
            desc = "Run: \(String(cmd.prefix(50)))"
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

        let approval = ApprovalRequest(
            toolName: toolName, actionSummary: desc,
            question: question, options: options
        )

        pendingApproval = approval
        UserDefaults.standard.set(permissionId, forKey: "watch_pending_permission")

        // Also store on the specific session
        if let sid = sessionId, let idx = sessionIndex(for: sid) {
            sessions[idx].pendingApproval = approval
            sessions[idx].activity = .waitingApproval
            // Auto-switch to the session that needs approval
            activeSessionIndex = idx
        }

        HapticManager.approvalNeeded()
    }

    private func handleSessionEvent(_ json: [String: Any], sessionId: String?) {
        let state = json["state"] as? String ?? ""
        let agent = json["agent"] as? String
        let cwd = json["cwd"] as? String ?? ""
        let folderName = json["folderName"] as? String ?? ""

        switch state {
        case "running":
            isStreaming = true
            if let sid = sessionId {
                if let idx = sessionIndex(for: sid) {
                    sessions[idx].activity = .running
                } else {
                    // New session appeared
                    let agentType = AgentType(rawValue: agent ?? "claude") ?? .claude
                    let newSession = AgentSession(
                        id: sid, agent: agentType, cwd: cwd,
                        folderName: folderName, activity: .running
                    )
                    sessions.append(newSession)
                    // Auto-switch to the new session
                    activeSessionIndex = sessions.count - 1
                }
            }

        case "ended":
            isStreaming = false
            if let sid = sessionId, let idx = sessionIndex(for: sid) {
                sessions[idx].activity = .ended
                appendLine(TerminalLine(text: "Session ended", type: .system), sessionId: sid)
            } else {
                appendLine(TerminalLine(text: "Session ended", type: .system))
            }

        case "connected":
            // Bridge-level: watch paired
            break

        default:
            break
        }
    }

    // MARK: - Permission response

    func respondToPermissionWithOption(_ optionLabel: String) {
        guard let permissionId = UserDefaults.standard.string(forKey: "watch_pending_permission"),
              let baseURL = bridge.baseURL, let token = bridge.token else { return }

        pendingApproval = nil
        // Clear from session
        if let session = activeSession, let idx = sessionIndex(for: session.id) {
            sessions[idx].pendingApproval = nil
            sessions[idx].activity = .running
        }

        let url = baseURL.appendingPathComponent("command")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "permissionId": permissionId,
            "decision": ["behavior": "allow"],
            "selectedOption": optionLabel
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request).resume()
        appendLine(TerminalLine(text: "→ \(optionLabel)", type: .command), sessionId: activeSession?.id)
        UserDefaults.standard.removeObject(forKey: "watch_pending_permission")
    }

    func respondToPermission(approved: Bool) {
        guard let permissionId = UserDefaults.standard.string(forKey: "watch_pending_permission"),
              let baseURL = bridge.baseURL, let token = bridge.token else { return }

        pendingApproval = nil
        if let session = activeSession, let idx = sessionIndex(for: session.id) {
            sessions[idx].pendingApproval = nil
            sessions[idx].activity = .running
        }

        let url = baseURL.appendingPathComponent("command")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "permissionId": permissionId,
            "decision": ["behavior": approved ? "allow" : "deny"]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error { print("[WatchViewState] Permission response failed: \(error)") }
        }.resume()

        appendLine(
            TerminalLine(text: approved ? "✓ Approved" : "✗ Denied", type: approved ? .output : .error),
            sessionId: activeSession?.id
        )
        UserDefaults.standard.removeObject(forKey: "watch_pending_permission")
    }

    // MARK: - Voice command (direct to bridge)

    func sendVoiceCommand(_ text: String, sessionId: String? = nil) {
        let sid = sessionId ?? activeSession?.id
        appendLine(TerminalLine(text: "> \(text)", type: .command), sessionId: sid)
        appendLine(TerminalLine(text: "", type: .thinking), sessionId: sid)

        guard let baseURL = bridge.baseURL, let token = bridge.token else { return }

        let url = baseURL.appendingPathComponent("command")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = ["command": text + "\n"]
        if let sid { body["sessionId"] = sid }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error { print("[WatchViewState] Command send failed: \(error)") }
        }.resume()
    }

    // MARK: - Token rejected (bridge restarted)

    func handleTokenRejected() {
        print("[WatchViewState] Token rejected — resetting to pairing screen")
        stopEventStream()
        bridge.unpair()
        isPaired = false
        terminalLines = []
        sessions = []
        activeSessionIndex = 0
        pendingApproval = nil
        isStreaming = false
        sessionState = .disconnected
    }

    // MARK: - Helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - SSE URLSession Delegate

private class SSEDelegate: NSObject, URLSessionDataDelegate {
    weak var owner: WatchViewState?

    init(owner: WatchViewState) {
        self.owner = owner
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        owner?.handleSSEData(text)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            print("[SSE] Token rejected (401) — bridge restarted, need to re-pair")
            DispatchQueue.main.async { [weak self] in
                self?.owner?.handleTokenRejected()
            }
            return .cancel
        }
        return .allow
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            print("[SSE] Connection lost: \(error.localizedDescription)")
        }

        if let http = task.response as? HTTPURLResponse, http.statusCode == 401 {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let owner = self?.owner, owner.isPaired else { return }
            owner.startEventStream()
        }
    }
}
