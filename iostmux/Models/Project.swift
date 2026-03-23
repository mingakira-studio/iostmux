import Foundation

enum SessionState {
    case none       // no tmux session
    case idle       // waiting at ❯ prompt
    case active     // Claude is outputting
    case done       // was working, now idle, not yet viewed
}

struct Project: Identifiable {
    let id = UUID()
    let name: String
    var hasActiveSession: Bool
    var sessionState: SessionState = .none
    var area: String = ""
    var lastUpdated: String = ""  // YYYY-MM-DD from PROJECT.md
    var lastActivity: Int = 0    // Unix timestamp from tmux session_activity

    /// Sort: working first, then idle, then none. Within same state, by lastUpdated desc then name.
    var sortOrder: Int {
        switch sessionState {
        case .done: 0
        case .active: 1
        case .idle: 2
        case .none: 3
        }
    }
}
