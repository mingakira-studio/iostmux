import Foundation

class OutputFilter {
    enum State {
        case show
        case toolBlock
    }

    private(set) var state: State = .show
    private let toolKeywords = ["Read", "Write", "Edit", "Bash", "Grep", "Glob",
                                 "Agent", "Skill", "WebSearch", "WebFetch",
                                 "LSP", "TodoWrite", "NotebookEdit"]
    private let alwaysHidePatterns = [
        "Allow .+\\? \\[Y/n\\]",
        "Ctrl\\+C to interrupt",
    ]
    private let alwaysShowPatterns = [
        "❯",
        "^>",
        "^Error",
        "^Warning",
    ]

    func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1b}\\[[0-9;]*[A-Za-z]|\u{1b}\\].*?\u{07}|\u{1b}\\].*?\u{1b}\\\\",
            with: "",
            options: .regularExpression
        )
    }

    func shouldShow(line: String) -> Bool {
        let clean = stripANSI(line).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return state == .show }

        for pattern in alwaysHidePatterns {
            if clean.range(of: pattern, options: .regularExpression) != nil {
                return false
            }
        }

        for pattern in alwaysShowPatterns {
            if clean.range(of: pattern, options: .regularExpression) != nil {
                state = .show
                return true
            }
        }

        if clean.contains("\u{23FA}") { // ⏺
            let isToolCall = toolKeywords.contains { clean.contains("\u{23FA} \($0)") || clean.contains("\u{23FA}  \($0)") }
            if isToolCall {
                state = .toolBlock
                return false
            } else {
                state = .show
                return true
            }
        }

        return state == .show
    }

    func reset() {
        state = .show
    }
}
