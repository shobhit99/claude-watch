import Foundation

struct TerminalLine: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    let type: LineType

    enum LineType: String, Codable {
        case output      // Claude's output
        case command     // User's command (prefixed with >)
        case system      // System messages (connected, disconnected, etc.)
        case thinking    // Pulsing cursor indicator
        case error       // Error messages
    }

    init(text: String, type: LineType = .output) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.type = type
    }
}
