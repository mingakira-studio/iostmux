import Foundation

enum LineType: String {
    case aiText       // Claude's response — white
    case humanInput   // User's message — light blue
    case toolCall     // Tool summary — gray with dot
    case toolError    // Failed tool — gray with red dot
    case info         // Cost/time info — dim gray
}

struct ClaudeStatus {
    var workDir: String = ""
    var model: String = ""
    var contextSize: String = ""
    var contextUsage: Int = 0  // percentage 0-100
}

struct FilteredLine: Identifiable {
    let id = UUID()
    let text: String
    let type: LineType
}

class OutputFilter {
    enum State {
        case show
        case humanInput
        case toolBlock
        case codeBlock
    }

    private(set) var state: State = .show

    /// Detect if text after marker is a tool call.
    /// Patterns: "Bash(cmd)", "Read 1 file", "Web Search("query")", "Agent(task)"
    private func isToolCall(_ text: String) -> Bool {
        // Pattern 1: "Word(" or "Word Word(" — tool call with args in parens
        // Look for ( within first 30 chars preceded by ASCII letters
        if let parenIdx = text.firstIndex(of: "(") {
            let prefix = text[text.startIndex..<parenIdx]
            if prefix.count <= 25 && prefix.allSatisfy({ $0.isLetter || $0 == " " }) {
                let words = prefix.split(separator: " ")
                if let first = words.first, first.first?.isUppercase == true && first.allSatisfy({ $0.isASCII }) {
                    return true
                }
            }
        }
        // Pattern 2: "Read 1 file" — known single-word tool + number
        let firstWord = String(text.split(separator: " ", maxSplits: 1).first ?? "")
        if OutputFilter.knownSingleTools.contains(firstWord) {
            return true
        }
        return false
    }

    private static let knownSingleTools: Set<String> = [
        "Read", "Write", "Edit", "Bash", "Glob", "Grep", "Agent",
        "Search", "Task", "Skill", "LSP",
    ]


    func processLine(_ rawLine: String) -> FilteredLine? {
        let clean = rawLine.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }

        // --- Always hide ---

        // Horizontal dividers
        if clean.allSatisfy({ "─━═╌—-".contains($0) }) && clean.count > 3 { return nil }

        // Claude Code UI chrome
        if clean.contains("bypass permissions") { return nil }
        if clean.contains("shift+tab to cycle") { return nil }
        if clean.contains("Update available! Run:") { return nil }
        if clean.contains("brew upgrade claude") { return nil }
        if clean.contains("Ctrl+C to interrupt") || clean.contains("Ctrl-C") { return nil }
        if clean.contains("q:qu...:") { return nil }
        if clean.hasPrefix("│") || clean.hasPrefix("║") { return nil }
        if clean.hasPrefix("└") || clean.hasPrefix("├") || clean.hasPrefix("┌") { return nil }

        // tmux status bar
        if clean.range(of: "^\\s*\\S+\\s+\\d+:\\w+", options: .regularExpression) != nil { return nil }

        // Pane 2 leftovers
        if clean.contains("任务大纲") && clean.contains("||") { return nil }
        if clean.range(of: "\\|\\|\\s*\\d+\\.\\s*(✓|▶|►)", options: .regularExpression) != nil { return nil }
        if clean.hasPrefix("| Area:") || clean.contains("| ├─") || clean.contains("| └─") { return nil }

        // Claude Code status bar (captured separately for top display)
        if clean.hasPrefix("~/") && clean.contains("context") { return nil }
        if clean.hasPrefix("⏵⏵") || clean.hasPrefix(">>") { return nil }

        // Permission prompts
        if clean.range(of: "Allow .+\\? \\[Y/n\\]", options: .regularExpression) != nil { return nil }

        // --- Tool call detection (marker must be at line start) ---

        let toolMarkers = ["⏺", "●"]
        for marker in toolMarkers {
            if clean.hasPrefix(marker) {
                let afterMarker = String(clean.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)

                if isToolCall(afterMarker) {
                    state = .toolBlock
                    let words = afterMarker.split(separator: " ", maxSplits: 3).prefix(3)
                    let summary = words.joined(separator: " ")
                    return FilteredLine(text: summary, type: .toolCall)
                }
                // Not a tool call — it's Claude's response text
                state = .show
                return afterMarker.isEmpty ? nil : FilteredLine(text: afterMarker, type: .aiText)
            }
        }

        // --- Tool output (always hide) ---

        if clean.hasPrefix("⎿") { return nil }
        if clean.hasPrefix("(timeout") { return nil }
        if clean.contains("ctrl+o to expand") { return nil }
        if clean.range(of: "^\\.\\.\\. \\+\\d+ lines", options: .regularExpression) != nil { return nil }
        // File change summaries
        if clean.range(of: "^Added \\d+ lines", options: .regularExpression) != nil { return nil }
        if clean.range(of: "^Removed \\d+ lines", options: .regularExpression) != nil { return nil }
        if clean.range(of: "^\\d+ files? changed", options: .regularExpression) != nil { return nil }

        // --- In tool block or code block: hide everything until next marker ---

        if state == .toolBlock || state == .codeBlock {
            // Exit conditions: next tool call marker, human prompt, or Claude response marker
            let hasMarker = ["⏺", "●"].contains(where: { clean.hasPrefix($0) })
            let hasPrompt = clean.hasPrefix("❯") || clean.hasPrefix("\u{276F}")
            let hasInfo = clean.hasPrefix("✻") || clean.hasPrefix("*")

            if hasMarker || hasPrompt || hasInfo {
                state = .show
                // Don't return — fall through to process this line normally below
            } else {
                return nil  // Still in tool/code block, hide
            }
        }

        // --- Code/diff content detection (enter code block) ---

        // Line numbers + code
        if clean.range(of: "^\\d+\\s+[a-zA-Z@{}().\\s]", options: .regularExpression) != nil {
            state = .codeBlock
            return nil
        }
        // Diff markers
        if clean.range(of: "^\\d+\\s*[+-]\\s", options: .regularExpression) != nil {
            state = .codeBlock
            return nil
        }
        // File headers from Write/Update/Create tools
        if (clean.hasPrefix("Update(") || clean.hasPrefix("Create(") || clean.hasPrefix("Write(") || clean.hasPrefix("Read(")) && clean.hasSuffix(")") {
            state = .codeBlock
            return nil
        }

        // --- Human input ---

        if clean.hasPrefix("❯") || clean.hasPrefix("\u{276F}") {
            let text = clean
                .replacingOccurrences(of: "❯", with: "")
                .replacingOccurrences(of: "\u{276F}", with: "")
                .trimmingCharacters(in: .whitespaces)
            state = .humanInput
            return text.isEmpty ? nil : FilteredLine(text: "❯ \(text)", type: .humanInput)
        }

        // --- Human input continuation (multi-line user message) ---

        if state == .humanInput {
            return FilteredLine(text: clean, type: .humanInput)
        }

        // --- Info lines ---

        if clean.hasPrefix("✻") || clean.hasPrefix("*") && clean.contains("for") {
            state = .show
            return FilteredLine(text: clean, type: .info)
        }

        // --- Default: AI text ---

        state = .show
        return FilteredLine(text: clean, type: .aiText)
    }


    /// Extract Claude Code status bar info from raw capture-pane lines
    func extractStatus(from lines: [String]) -> ClaudeStatus? {
        var status = ClaudeStatus()
        for line in lines {
            let clean = line.trimmingCharacters(in: .whitespaces)
            // Match: ~/Projects/xxx  Model (context)  [███...
            if clean.hasPrefix("~/") && clean.contains("context") {
                // Extract work dir
                let parts = clean.components(separatedBy: "  ").filter { !$0.isEmpty }
                if parts.count >= 1 {
                    status.workDir = parts[0].trimmingCharacters(in: .whitespaces)
                }
                // Extract model + context from remaining parts
                for part in parts.dropFirst() {
                    let p = part.trimmingCharacters(in: .whitespaces)
                    if p.contains("context") {
                        // e.g. "Opus 4.6 (1M context)"
                        if let parenStart = p.firstIndex(of: "(") {
                            status.model = String(p[p.startIndex..<parenStart]).trimmingCharacters(in: .whitespaces)
                            let inside = String(p[parenStart...]).replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                            status.contextSize = inside.trimmingCharacters(in: .whitespaces)
                        } else {
                            status.model = p
                        }
                    }
                    if p.hasPrefix("[") {
                        // Context usage bar: [██████░░░░] XX% or [███████…
                        let filled = p.filter { $0 == "█" || $0 == "▓" }.count
                        let empty = p.filter { $0 == "░" }.count
                        let total = filled + empty
                        if total > 0 {
                            status.contextUsage = Int(Double(filled) / Double(total) * 100)
                        }
                    }
                }
                // Also try to find "XX% used" or just "XX%" anywhere in the line
                if status.contextUsage == 0 {
                    if let match = clean.range(of: #"(\d+)%\s*(used)?"#, options: .regularExpression) {
                        let pctStr = clean[match].filter { $0.isNumber }
                        if let pct = Int(pctStr) {
                            status.contextUsage = pct
                        }
                    }
                }
                return status
            }
        }
        return nil
    }

    func reset() {
        state = .show
    }
}
