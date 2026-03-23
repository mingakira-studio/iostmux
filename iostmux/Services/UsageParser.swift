import Foundation

struct UsageQuota {
    var fiveHourUtil: Double = 0
    var fiveHourReset: String = ""
    var sevenDayUtil: Double = 0
    var sevenDayReset: String = ""
}

enum UsageParser {
    static func parse(_ jsonString: String) -> UsageQuota? {
        guard let data = jsonString.data(using: .utf8),
              let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Support both direct format {"five_hour":...} and cache format {"_data":{...}}
        let dict: [String: Any]
        if let inner = wrapper["_data"] as? [String: Any] {
            dict = inner
        } else {
            dict = wrapper
        }

        var quota = UsageQuota()

        if let fiveHour = dict["five_hour"] as? [String: Any] {
            quota.fiveHourUtil = fiveHour["utilization"] as? Double ?? 0
            quota.fiveHourReset = formatRemaining(fiveHour["resets_at"] as? String)
        }

        if let sevenDay = dict["seven_day"] as? [String: Any] {
            quota.sevenDayUtil = sevenDay["utilization"] as? Double ?? 0
            quota.sevenDayReset = formatRemaining(sevenDay["resets_at"] as? String)
        }

        return quota
    }

    private static func formatRemaining(_ isoString: String?) -> String {
        guard let isoString, !isoString.isEmpty else { return "-" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let resetDate = formatter.date(from: isoString)
                ?? ISO8601DateFormatter().date(from: isoString)
        else { return "-" }

        let remaining = resetDate.timeIntervalSinceNow
        guard remaining > 0 else { return "已重置" }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
