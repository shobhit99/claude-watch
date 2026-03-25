import SwiftUI
import WatchConnectivity

class WatchViewState: ObservableObject {
    static let shared = WatchViewState()

    @Published var isPaired: Bool = false
    @Published var sessionState: SessionState = .disconnected
    @Published var terminalLines: [TerminalLine] = []
    @Published var pendingApproval: ApprovalRequest? = nil
    @Published var isStreaming: Bool = false
    @Published var taskCompleteSummary: String? = nil
    @Published var isReachable: Bool = false

    private let bridge = WatchBridgeClient.shared
    private let maxLines = 200
    private var pollTimer: Timer?
    private var lastEventId: Int = 0
    private var sseTask: URLSessionDataTask?

    private init() {
        // Verify saved credentials by checking the bridge
        if bridge.isPaired {
            Task {
                let reachable = await verifyBridge()
                await MainActor.run {
                    if reachable {
                        isPaired = true
                        startEventStream()
                    } else {
                        // Bridge unreachable — clear stale credentials
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

    // MARK: - Terminal

    func appendLine(_ line: TerminalLine) {
        DispatchQueue.main.async {
            self.terminalLines.append(line)
            if self.terminalLines.count > self.maxLines {
                self.terminalLines.removeFirst(self.terminalLines.count - self.maxLines)
            }
        }
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
        request.timeoutInterval = 300 // Long timeout for SSE

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
        // Parse SSE format: "id: N\nevent: type\ndata: json\n\n"
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
                    // Comment (heartbeat) — ignore
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

        switch type {
        case "tool-output":
            let toolName = json["tool_name"] as? String ?? "tool"
            let toolInput = json["tool_input"] as? [String: Any] ?? [:]

            switch toolName {
            case "Bash":
                let cmd = toolInput["command"] as? String ?? ""
                appendLine(TerminalLine(text: "$ \(cmd)", type: .command))
            case "Read":
                let path = toolInput["file_path"] as? String ?? ""
                appendLine(TerminalLine(text: "Read \((path as NSString).lastPathComponent)", type: .system))
            case "Edit":
                let path = toolInput["file_path"] as? String ?? ""
                appendLine(TerminalLine(text: "Edit \((path as NSString).lastPathComponent)", type: .system))
            case "Write":
                let path = toolInput["file_path"] as? String ?? ""
                appendLine(TerminalLine(text: "Write \((path as NSString).lastPathComponent)", type: .system))
            case "Grep":
                let pattern = toolInput["pattern"] as? String ?? ""
                appendLine(TerminalLine(text: "grep \"\(pattern)\"", type: .command))
            default:
                appendLine(TerminalLine(text: "[\(toolName)]", type: .system))
            }
            isStreaming = true

        case "permission-request":
            let permissionId = json["permissionId"] as? String ?? UUID().uuidString
            let toolName = json["tool_name"] as? String ?? "Unknown"
            let toolInput = json["tool_input"] as? [String: Any] ?? [:]

            var question: String? = nil
            var desc = toolName
            var options: [ApprovalRequest.OptionItem] = []

            // Parse AskUserQuestion format
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
            }
            // Fallback for Edit/Bash/etc permission prompts
            else if let path = toolInput["file_path"] as? String {
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

            pendingApproval = ApprovalRequest(
                toolName: toolName, actionSummary: desc,
                question: question, options: options
            )
            UserDefaults.standard.set(permissionId, forKey: "watch_pending_permission")
            HapticManager.approvalNeeded()

        case "stop":
            appendLine(TerminalLine(text: "— stopped —", type: .system))
            isStreaming = false

        case "session":
            let state = json["state"] as? String ?? ""
            if state == "running" {
                isStreaming = true
            } else if state == "ended" {
                isStreaming = false
                appendLine(TerminalLine(text: "Session ended", type: .system))
            }

        case "pty-output":
            // Raw PTY output — show it
            if let text = json["text"] as? String {
                let cleaned = text.replacingOccurrences(
                    of: "\\x1B\\[[0-9;]*[a-zA-Z]",
                    with: "",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    appendLine(TerminalLine(text: String(cleaned.prefix(80)), type: .output))
                }
            }

        default:
            break
        }
    }

    // MARK: - Permission response

    /// Respond with a specific option label (for AskUserQuestion)
    func respondToPermissionWithOption(_ optionLabel: String) {
        guard let permissionId = UserDefaults.standard.string(forKey: "watch_pending_permission"),
              let baseURL = bridge.baseURL, let token = bridge.token else { return }

        pendingApproval = nil

        let url = baseURL.appendingPathComponent("command")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // For AskUserQuestion, we send "allow" with the selected option
        let body: [String: Any] = [
            "permissionId": permissionId,
            "decision": ["behavior": "allow"],
            "selectedOption": optionLabel
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request).resume()
        appendLine(TerminalLine(text: "→ \(optionLabel)", type: .command))
        UserDefaults.standard.removeObject(forKey: "watch_pending_permission")
    }

    func respondToPermission(approved: Bool) {
        guard let permissionId = UserDefaults.standard.string(forKey: "watch_pending_permission"),
              let baseURL = bridge.baseURL, let token = bridge.token else { return }

        pendingApproval = nil

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

        appendLine(TerminalLine(text: approved ? "✓ Approved" : "✗ Denied", type: approved ? .output : .error))
        UserDefaults.standard.removeObject(forKey: "watch_pending_permission")
    }

    // MARK: - Voice command (direct to bridge)

    func sendVoiceCommand(_ text: String) {
        appendLine(TerminalLine(text: "> \(text)", type: .command))
        appendLine(TerminalLine(text: "", type: .thinking))

        guard let baseURL = bridge.baseURL, let token = bridge.token else { return }

        let url = baseURL.appendingPathComponent("command")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["command": text + "\n"])

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

        // Check if it was a 401 (already handled above)
        if let http = task.response as? HTTPURLResponse, http.statusCode == 401 {
            return
        }

        // Reconnect after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let owner = self?.owner, owner.isPaired else { return }
            owner.startEventStream()
        }
    }
}
