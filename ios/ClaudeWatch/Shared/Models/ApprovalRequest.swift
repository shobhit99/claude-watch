import Foundation

struct ApprovalRequest: Identifiable, Codable {
    let id: UUID
    let toolName: String
    let actionSummary: String
    let timestamp: Date
    var status: ApprovalStatus
    var question: String?
    var options: [OptionItem]

    enum ApprovalStatus: String, Codable {
        case pending
        case approved
        case denied
        case expired
    }

    struct OptionItem: Identifiable, Codable {
        let id: UUID
        let label: String
        let description: String?

        init(label: String, description: String? = nil) {
            self.id = UUID()
            self.label = label
            self.description = description
        }
    }

    init(toolName: String, actionSummary: String, question: String? = nil, options: [OptionItem] = []) {
        self.id = UUID()
        self.toolName = toolName
        self.actionSummary = actionSummary
        self.timestamp = Date()
        self.status = .pending
        self.question = question
        self.options = options
    }
}
