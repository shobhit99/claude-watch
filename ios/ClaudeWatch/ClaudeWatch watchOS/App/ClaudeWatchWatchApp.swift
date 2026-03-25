import SwiftUI

// MARK: - Color Extension (hex init)

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Design Tokens

enum Theme {
    enum Background {
        static let primary = Color(hex: "000000")
        static let capture = Color(hex: "1a2233")
        static let overlay = Color(hex: "1a1a1a")
    }

    enum Text {
        static let primary = Color(hex: "E87A35")
        static let secondary = Color(hex: "666666")
        static let dimmed = Color(hex: "555555")
    }

    enum Accent {
        static let success = Color(hex: "34C759")
        static let error = Color(hex: "FF3B30")
        static let approval = Color(hex: "E8A735")
    }
}

// MARK: - WatchSessionManager

/// Manages WCSession communication between the watch and its paired iPhone.
/// Placeholder implementation -- the real WCSession delegate logic will be added
/// once the iOS counterpart is wired up.
class WatchSessionManager: ObservableObject {
    static let shared = WatchSessionManager()

    @Published var isPaired: Bool = false
    @Published var sessionState: SessionState = .disconnected
    @Published var terminalLines: [TerminalLine] = []
    @Published var pendingApproval: ApprovalRequest? = nil
    @Published var isStreaming: Bool = false
    @Published var taskCompleteSummary: String? = nil

    // MARK: - Output ring buffer (keeps last N lines to save memory)

    private let maxLines = 200

    func appendLine(_ line: TerminalLine) {
        terminalLines.append(line)
        if terminalLines.count > maxLines {
            terminalLines.removeFirst(terminalLines.count - maxLines)
        }
    }

    func sendVoiceCommand(_ text: String) {
        let commandLine = TerminalLine(text: "> \(text)", type: .command)
        appendLine(commandLine)

        // Add thinking indicator
        let thinkingLine = TerminalLine(text: "", type: .thinking)
        appendLine(thinkingLine)

        // TODO: Send via WCSession
        // let message = WatchMessage.voiceCommand(.init(transcribedText: text))
    }

    func respondToApproval(requestId: UUID, approved: Bool) {
        // TODO: Send via WCSession
        // let message = WatchMessage.approvalResponse(.init(requestId: requestId, approved: approved))
        pendingApproval = nil
    }
}

// MARK: - App Entry Point

@main
struct ClaudeWatchWatchApp: App {
    @StateObject private var sessionManager = WatchSessionManager.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if sessionManager.isPaired {
                    SessionView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(sessionManager)
        }
    }
}
