import Foundation

struct TerminalLine: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    let type: LineType
    let sessionId: String?

    enum LineType: String, Codable {
        case output      // Claude's output
        case command     // User's command (prefixed with >)
        case system      // System messages (connected, disconnected, etc.)
        case thinking    // Pulsing cursor indicator
        case error       // Error messages
    }

    init(text: String, type: LineType = .output, sessionId: String? = nil) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.type = type
        self.sessionId = sessionId
    }
}
