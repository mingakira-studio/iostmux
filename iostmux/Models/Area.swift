import Foundation

struct AreaRecord: Identifiable {
    let id = UUID()
    let name: String
    var projectCount: Int = 0
    var standards: String = ""
    var goals: String = ""
    var reviewNotes: String = ""
}

enum AreaParser {
    static func parse(_ content: String, name: String) -> AreaRecord {
        var area = AreaRecord(name: name)
        area.standards = extractSection(content, heading: "维护标准")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        area.goals = extractSection(content, heading: "中期目标")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        area.reviewNotes = extractSection(content, heading: "审视记录")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Fallback section names
        if area.standards.isEmpty {
            area.standards = extractSection(content, heading: "Standards")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if area.goals.isEmpty {
            area.goals = extractSection(content, heading: "Goals")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return area
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
}
