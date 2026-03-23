import Foundation

struct GTDProject: Identifiable {
    let id = UUID()
    var dirName: String = ""  // directory name in ~/Projects/
    var name: String = ""     // display name from # heading
    var area: String = ""
    var status: String = ""
    var goal: String = ""
    var outline: [OutlineItem] = []
    var nextTitle: String = ""
    var subtasks: [Subtask] = []
    var notes: [String] = []

    var outlineProgress: (done: Int, total: Int) {
        let done = outline.filter { $0.status == "x" }.count
        return (done, outline.count)
    }
}

struct OutlineItem: Identifiable {
    let id = UUID()
    let index: Int
    let status: String   // "x", " ", ">", "-"
    let title: String
    var isCurrent: Bool { status == ">" }
}

struct Subtask: Identifiable {
    let id = UUID()
    let status: String   // "x", " ", ">", "-"
    let title: String
    let estimate: String
    let kind: String
}

enum GTDParser {

    static func parse(_ content: String) -> GTDProject {
        var project = GTDProject()

        // Extract name from first heading
        if let firstLine = content.components(separatedBy: "\n").first,
           firstLine.hasPrefix("# ") {
            project.name = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        // Parse Meta section
        let meta = extractSection(content, heading: "Meta")
        for line in meta.components(separatedBy: "\n") {
            let clean = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("- Area:") {
                project.area = clean.replacingOccurrences(of: "- Area:", with: "").trimmingCharacters(in: .whitespaces)
            } else if clean.hasPrefix("- Status:") {
                project.status = clean.replacingOccurrences(of: "- Status:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }

        // Parse goal
        project.goal = extractSection(content, heading: "目标").trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse task outline
        let outlineText = extractSection(content, heading: "任务大纲")
        project.outline = parseOutline(outlineText)

        // Parse NEXT section
        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("## NEXT:") {
                project.nextTitle = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                // Find subtasks
                let remaining = lines[(i+1)...].joined(separator: "\n")
                project.subtasks = parseSubtasks(remaining)
                break
            }
        }

        // If no explicit NEXT section, derive from outline
        if project.nextTitle.isEmpty {
            if let current = project.outline.first(where: { $0.isCurrent }) {
                project.nextTitle = current.title
            }
        }

        // Parse notes from 项目备忘
        let notesText = extractSection(content, heading: "项目备忘")
        project.notes = notesText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<!--") && !$0.hasSuffix("-->") }

        return project
    }

    private static func extractSection(_ content: String, heading: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var capturing = false
        var result: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if capturing { break }
                let h = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if h.hasPrefix(heading) {
                    capturing = true
                    continue
                }
            }
            if capturing {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private static func parseOutline(_ text: String) -> [OutlineItem] {
        var items: [OutlineItem] = []
        var index = 0

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match top-level items: "- [x] Title" or "1. [x] Title"
            // Skip indented sub-items (lines starting with spaces + -)
            guard !trimmed.isEmpty else { continue }

            // Only match top-level (no leading spaces beyond list marker)
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            guard leadingSpaces <= 2 else { continue }

            if trimmed.range(of: #"^\-\s*\[(.)\]\s*"#, options: .regularExpression) != nil ||
               trimmed.range(of: #"^\d+\.\s*\[(.)\]\s*"#, options: .regularExpression) != nil {
                // Extract status character between [ ]
                if let bracketStart = trimmed.firstIndex(of: "["),
                   let bracketEnd = trimmed.firstIndex(of: "]"),
                   bracketStart < bracketEnd {
                    let status = String(trimmed[trimmed.index(after: bracketStart)..<bracketEnd])
                    let titleStart = trimmed.index(after: bracketEnd)
                    var title = String(trimmed[titleStart...]).trimmingCharacters(in: .whitespaces)
                    // Remove trailing date like (2026-03-18)
                    if let dateRange = title.range(of: #"\s*\(\d{4}-\d{2}-\d{2}\)\s*$"#, options: .regularExpression) {
                        title = String(title[..<dateRange.lowerBound])
                    }
                    // Remove trailing " — note"
                    if let dashRange = title.range(of: #"\s*—\s*.*$"#, options: .regularExpression) {
                        title = String(title[..<dashRange.lowerBound])
                    }
                    index += 1
                    items.append(OutlineItem(index: index, status: status, title: title))
                }
            }
        }
        return items
    }

    private static func parseSubtasks(_ text: String) -> [Subtask] {
        var tasks: [Subtask] = []
        let subtaskSection = extractSection("## dummy\n" + text, heading: "子任务")

        for line in subtaskSection.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [") else { continue }

            if let bracketStart = trimmed.firstIndex(of: "["),
               let bracketEnd = trimmed.firstIndex(of: "]"),
               bracketStart < bracketEnd {
                let status = String(trimmed[trimmed.index(after: bracketStart)..<bracketEnd])
                let rest = String(trimmed[trimmed.index(after: bracketEnd)...]).trimmingCharacters(in: .whitespaces)

                // Extract title (possibly bold)
                var title = rest
                var estimate = ""
                var kind = ""

                // Split by | for metadata
                let parts = title.components(separatedBy: "|")
                if parts.count > 1 {
                    title = parts[0].trimmingCharacters(in: .whitespaces)
                    for part in parts.dropFirst() {
                        let p = part.trimmingCharacters(in: .whitespaces)
                        if p.hasPrefix("预估:") || p.hasPrefix("预估：") {
                            estimate = p.replacingOccurrences(of: "预估:", with: "")
                                .replacingOccurrences(of: "预估：", with: "")
                                .trimmingCharacters(in: .whitespaces)
                        } else if p.hasPrefix("类型:") || p.hasPrefix("类型：") {
                            kind = p.replacingOccurrences(of: "类型:", with: "")
                                .replacingOccurrences(of: "类型：", with: "")
                                .trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
                // Remove ** bold markers
                title = title.replacingOccurrences(of: "**", with: "")

                tasks.append(Subtask(status: status, title: title, estimate: estimate, kind: kind))
            }
        }
        return tasks
    }
}
