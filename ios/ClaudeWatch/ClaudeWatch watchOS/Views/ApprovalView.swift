import SwiftUI
import WatchKit

struct ApprovalView: View {
    @EnvironmentObject private var session: WatchViewState
    @Environment(\.dismiss) private var dismiss

    let request: ApprovalRequest
    @State private var hasResponded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Question text
                if let question = request.question {
                    Text(question)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Do you want to \(request.toolName.lowercased())?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }

                // Action summary / header
                if !request.actionSummary.isEmpty && request.actionSummary != request.toolName {
                    Text(request.actionSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.Accent.approval)
                        .lineLimit(2)
                }

                Divider().background(Theme.Text.dimmed)

                // Dynamic options from server
                ForEach(Array(request.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        respond(option: option, index: index)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1).")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.Text.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(2)

                                if let desc = option.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.Text.secondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .background(colorForOption(index).opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(colorForOption(index).opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(hasResponded)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
        .background(Theme.Background.primary)
    }

    private func colorForOption(_ index: Int) -> Color {
        // First option: green, last option: red, middle: orange
        if request.options.count <= 1 { return Theme.Accent.success }
        if index == 0 { return Theme.Accent.success }
        if index == request.options.count - 1 { return Theme.Accent.error }
        return Theme.Text.primary
    }

    private func respond(option: ApprovalRequest.OptionItem, index: Int) {
        guard !hasResponded else { return }
        hasResponded = true

        let isLast = index == request.options.count - 1
        WKInterfaceDevice.current().play(isLast ? .failure : .success)

        // For AskUserQuestion: send the option label
        // For permission prompts: first = allow, last = deny
        if request.question != nil {
            session.respondToPermissionWithOption(option.label)
        } else {
            let approved = index != request.options.count - 1
            session.respondToPermission(approved: approved)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            dismiss()
        }
    }
}

#Preview {
    ApprovalView(
        request: ApprovalRequest(
            toolName: "AskUserQuestion",
            actionSummary: "Goal",
            question: "Before we dig in — what's your goal with this?",
            options: [
                .init(label: "Building a startup", description: "You're building a company"),
                .init(label: "Hackathon / fun", description: "Time-boxed project"),
                .init(label: "Open source", description: "Building for a community"),
            ]
        )
    )
    .environmentObject(WatchViewState.shared)
}
