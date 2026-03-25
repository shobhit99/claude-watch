import Foundation

enum ConnectionState: String, Codable {
    case disconnected
    case connecting
    case connected
    case iPhoneUnreachable
}

enum SessionActivity: String, Codable {
    case idle
    case running
    case waitingApproval
    case ended
}

struct SessionState: Codable {
    var connection: ConnectionState
    var activity: SessionActivity
    var machineName: String?
    var modelName: String?
    var workingDirectory: String?
    var elapsedSeconds: Int
    var filesChanged: Int
    var linesAdded: Int
    var transportMode: TransportMode

    enum TransportMode: String, Codable {
        case lan
        case remote
    }

    static var disconnected: SessionState {
        SessionState(
            connection: .disconnected,
            activity: .idle,
            machineName: nil,
            modelName: nil,
            workingDirectory: nil,
            elapsedSeconds: 0,
            filesChanged: 0,
            linesAdded: 0,
            transportMode: .lan
        )
    }
}
