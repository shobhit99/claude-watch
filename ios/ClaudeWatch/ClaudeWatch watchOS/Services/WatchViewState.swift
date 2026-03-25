import SwiftUI
import WatchConnectivity

/// Watch-specific view state that wraps the shared WatchSessionManager.
/// Provides @Published properties that the watchOS SwiftUI views observe.
class WatchViewState: ObservableObject {
    static let shared = WatchViewState()

    @Published var isPaired: Bool = false
    @Published var sessionState: SessionState = .disconnected
    @Published var terminalLines: [TerminalLine] = []
    @Published var pendingApproval: ApprovalRequest? = nil
    @Published var isStreaming: Bool = false
    @Published var taskCompleteSummary: String? = nil
    @Published var isReachable: Bool = false

    private let connectivity = WatchSessionManager.shared
    private let maxLines = 200

    private init() {
        connectivity.activate()
        connectivity.onMessageReceived = { [weak self] message in
            self?.handleMessage(message)
        }
    }

    // MARK: - Terminal output

    func appendLine(_ line: TerminalLine) {
        DispatchQueue.main.async {
            self.terminalLines.append(line)
            if self.terminalLines.count > self.maxLines {
                self.terminalLines.removeFirst(self.terminalLines.count - self.maxLines)
            }
        }
    }

    // MARK: - Commands

    func sendVoiceCommand(_ text: String) {
        let commandLine = TerminalLine(text: "> \(text)", type: .command)
        appendLine(commandLine)

        let thinkingLine = TerminalLine(text: "", type: .thinking)
        appendLine(thinkingLine)

        let message = WatchMessage.voiceCommand(WatchMessage.VoiceCommand(transcribedText: text))
        connectivity.send(message)
    }

    func respondToApproval(requestId: UUID, approved: Bool) {
        let message = WatchMessage.approvalResponse(
            WatchMessage.ApprovalResponse(requestId: requestId, approved: approved)
        )
        connectivity.send(message)
        DispatchQueue.main.async {
            self.pendingApproval = nil
        }
    }

    // MARK: - Message handling

    private func handleMessage(_ message: WatchMessage) {
        DispatchQueue.main.async {
            switch message {
            case .terminalUpdate(let update):
                for line in update.lines {
                    self.appendLine(line)
                }
                self.terminalLines.removeAll { $0.type == .thinking }

            case .approvalRequestMessage(let request):
                // Associated value is ApprovalRequest directly
                self.pendingApproval = request
                HapticManager.approvalNeeded()

            case .sessionStateUpdate(let state):
                // Associated value is SessionState directly
                self.sessionState = state
                self.isPaired = true
                self.isStreaming = state.activity == .running

            case .connectionStatus(let status):
                self.isReachable = status.state == .connected

            default:
                break
            }
        }
    }
}
