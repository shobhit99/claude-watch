import Foundation

struct ApprovalRequest: Identifiable, Codable {
    let id: UUID
    let toolName: String
    let actionSummary: String
    let timestamp: Date
    var status: ApprovalStatus

    enum ApprovalStatus: String, Codable {
        case pending
        case approved
        case denied
        case expired
    }

    init(toolName: String, actionSummary: String) {
        self.id = UUID()
        self.toolName = toolName
        self.actionSummary = actionSummary
        self.timestamp = Date()
        self.status = .pending
    }
}
