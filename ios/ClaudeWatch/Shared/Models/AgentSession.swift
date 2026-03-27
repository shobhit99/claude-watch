import Foundation

enum AgentType: String, Codable {
    case claude
    case codex
}

struct AgentSession: Identifiable, Codable, Equatable {
    let id: String
    let agent: AgentType
    let cwd: String
    let folderName: String
    var activity: SessionActivity

    // Client-side only — not decoded from bridge JSON
    var terminalLines: [TerminalLine] = []
    var pendingApproval: ApprovalRequest?

    enum CodingKeys: String, CodingKey {
        case id, agent, cwd, folderName, activity
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(agent, forKey: .agent)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(folderName, forKey: .folderName)
        try c.encode(activity, forKey: .activity)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agent = try c.decodeIfPresent(AgentType.self, forKey: .agent) ?? .claude
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        activity = try c.decodeIfPresent(SessionActivity.self, forKey: .activity) ?? .idle
        terminalLines = []
        pendingApproval = nil
    }

    init(id: String, agent: AgentType, cwd: String, folderName: String, activity: SessionActivity) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.folderName = folderName
        self.activity = activity
        self.terminalLines = []
        self.pendingApproval = nil
    }

    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id
            && lhs.agent == rhs.agent
            && lhs.activity == rhs.activity
            && lhs.terminalLines.count == rhs.terminalLines.count
    }
}
