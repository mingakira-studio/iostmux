import Foundation

struct EvolveReport {
    var projectName: String = ""
    var health: String = ""
    var continueRec: String = ""
    var summary: String = ""
    var reportDate: String = ""
    var recommendations: [EvolveRecommendation] = []
}

struct EvolveRecommendation: Identifiable {
    let id = UUID()
    let index: Int
    let priority: String   // critical, high, medium, low
    let type: String        // quality, process, goal, architecture
    let description: String
    var action: String?     // accept, reject, done
    var actionType: String? // idea, task
}

enum EvolveParser {
    static func parse(_ jsonString: String) -> EvolveReport? {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let structured = root["structured_output"] as? [String: Any] ?? root
        guard !structured.isEmpty else { return nil }

        var report = EvolveReport()
        report.projectName = structured["project_name"] as? String ?? ""
        report.health = structured["health"] as? String ?? ""
        report.continueRec = structured["continue_recommendation"] as? String ?? ""
        report.summary = structured["summary"] as? String ?? ""

        if let recs = structured["top_recommendations"] as? [[String: Any]] {
            for (i, rec) in recs.enumerated() {
                report.recommendations.append(EvolveRecommendation(
                    index: i,
                    priority: rec["priority"] as? String ?? "medium",
                    type: rec["type"] as? String ?? "",
                    description: rec["description"] as? String ?? ""
                ))
            }
        }

        return report
    }

    /// Parse feedback JSONL and apply actions to recommendations
    static func applyFeedback(_ jsonlString: String, to report: inout EvolveReport, projectId: String) {
        for line in jsonlString.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["item_id"] as? String == projectId
            else { continue }

            let index = entry["insight_index"] as? Int ?? -1
            let action = entry["action"] as? String
            let actionType = entry["action_type"] as? String

            if index >= 0 && index < report.recommendations.count {
                report.recommendations[index].action = action
                report.recommendations[index].actionType = actionType
            }
        }
    }
}
