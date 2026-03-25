import Foundation

// MARK: - WatchMessage

/// All message types exchanged between the iOS app and watchOS app via WCSession.
/// Uses an enum with associated values for type safety, with dictionary serialization
/// for WCSession compatibility (WCSession requires [String: Any] dictionaries).
enum WatchMessage: Codable {

    // Watch -> iPhone
    case voiceCommand(VoiceCommand)
    case approvalResponse(ApprovalResponse)

    // iPhone -> Watch
    case terminalUpdate(TerminalUpdate)
    case approvalRequestMessage(ApprovalRequest)
    case sessionStateUpdate(SessionState)
    case connectionStatus(ConnectionStatusMessage)

    // MARK: - Payload Types

    struct VoiceCommand: Codable {
        let id: UUID
        let transcribedText: String
        let timestamp: Date

        init(transcribedText: String) {
            self.id = UUID()
            self.transcribedText = transcribedText
            self.timestamp = Date()
        }
    }

    struct ApprovalResponse: Codable {
        let requestId: UUID
        let approved: Bool
        let timestamp: Date

        init(requestId: UUID, approved: Bool) {
            self.requestId = requestId
            self.approved = approved
            self.timestamp = Date()
        }
    }

    struct TerminalUpdate: Codable {
        let lines: [TerminalLine]
        let timestamp: Date

        init(lines: [TerminalLine]) {
            self.lines = lines
            self.timestamp = Date()
        }
    }

    struct ConnectionStatusMessage: Codable {
        let state: ConnectionState
        let machineName: String?
        let timestamp: Date

        init(state: ConnectionState, machineName: String? = nil) {
            self.state = state
            self.machineName = machineName
            self.timestamp = Date()
        }
    }

    // MARK: - Dictionary keys

    private static let typeKey = "messageType"
    private static let payloadKey = "payload"

    private var typeIdentifier: String {
        switch self {
        case .voiceCommand:           return "voiceCommand"
        case .approvalResponse:       return "approvalResponse"
        case .terminalUpdate:         return "terminalUpdate"
        case .approvalRequestMessage: return "approvalRequestMessage"
        case .sessionStateUpdate:     return "sessionStateUpdate"
        case .connectionStatus:       return "connectionStatus"
        }
    }

    // MARK: - Dictionary serialization

    /// Converts the message to a `[String: Any]` dictionary suitable for WCSession.
    func toDictionary() -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(self),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fallback: at minimum include the type so the receiver can identify it.
            return [Self.typeKey: typeIdentifier]
        }
        return json
    }

    /// Reconstructs a `WatchMessage` from a `[String: Any]` dictionary received via WCSession.
    init(from dictionary: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(WatchMessage.self, from: data)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case messageType
        case payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeIdentifier, forKey: .messageType)

        switch self {
        case .voiceCommand(let cmd):
            try container.encode(cmd, forKey: .payload)
        case .approvalResponse(let resp):
            try container.encode(resp, forKey: .payload)
        case .terminalUpdate(let update):
            try container.encode(update, forKey: .payload)
        case .approvalRequestMessage(let req):
            try container.encode(req, forKey: .payload)
        case .sessionStateUpdate(let state):
            try container.encode(state, forKey: .payload)
        case .connectionStatus(let status):
            try container.encode(status, forKey: .payload)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .messageType)

        switch type {
        case "voiceCommand":
            self = .voiceCommand(try container.decode(VoiceCommand.self, forKey: .payload))
        case "approvalResponse":
            self = .approvalResponse(try container.decode(ApprovalResponse.self, forKey: .payload))
        case "terminalUpdate":
            self = .terminalUpdate(try container.decode(TerminalUpdate.self, forKey: .payload))
        case "approvalRequestMessage":
            self = .approvalRequestMessage(try container.decode(ApprovalRequest.self, forKey: .payload))
        case "sessionStateUpdate":
            self = .sessionStateUpdate(try container.decode(SessionState.self, forKey: .payload))
        case "connectionStatus":
            self = .connectionStatus(try container.decode(ConnectionStatusMessage.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .messageType,
                in: container,
                debugDescription: "Unknown message type: \(type)"
            )
        }
    }
}
