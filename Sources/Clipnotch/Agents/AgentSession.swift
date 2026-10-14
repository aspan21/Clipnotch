import SwiftUI

/// Where a Claude Code session stands, from the hook events it has sent.
enum AgentState: Equatable {
    case working
    /// A permission prompt has been waiting in the terminal.
    case needsPermission
    /// `AskUserQuestion`, or an MCP server asking for input.
    case question
    /// The turn ended and Claude is waiting for the next prompt.
    case finished
    /// The turn ended on an API error.
    case failed

    /// Everything but `working` is Claude sitting idle until you act.
    var needsYou: Bool { self != .working }

    var title: String {
        switch self {
        case .working: return String(localized: "Working")
        case .needsPermission: return String(localized: "Needs Permission")
        case .question: return String(localized: "Has a Question")
        case .finished: return String(localized: "Finished")
        case .failed: return String(localized: "Stopped on an Error")
        }
    }

    var symbol: String {
        switch self {
        case .working: return "ellipsis"
        case .needsPermission: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .working: return Theme.secondaryText
        case .needsPermission: return Color(red: 1.0, green: 0.62, blue: 0.26)
        case .question: return Color(red: 0.74, green: 0.56, blue: 1.0)
        case .finished: return Color(red: 0.33, green: 0.85, blue: 0.5)
        case .failed: return Color(red: 1.0, green: 0.38, blue: 0.36)
        }
    }

    /// Order in the list and in the closed strip: what blocks Claude hardest first.
    var urgency: Int {
        switch self {
        case .needsPermission: return 0
        case .question: return 1
        case .failed: return 2
        case .finished: return 3
        case .working: return 4
        }
    }
}

struct AgentSession: Identifiable, Equatable {
    let id: String
    var cwd: String
    var state: AgentState = .working
    /// Claude Code's own wording for a notification, e.g. "Claude needs your
    /// permission to use Bash".
    var detail: String?
    /// When `state` was entered.
    var since = Date()
    var lastEvent = Date()
    /// The app the session runs in, for "bring it forward".
    var bundleID: String?
    var termProgram: String?
    /// Seen already: clicked or dismissed in the list. Still listed, no
    /// longer counted.
    var acknowledged = false

    var project: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || cwd.isEmpty ? "Claude Code" : name
    }

    var needsAttention: Bool { state.needsYou && !acknowledged }
}
