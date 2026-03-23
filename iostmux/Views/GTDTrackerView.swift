import SwiftUI

struct GTDTrackerView: View {
    let project: GTDProject
    var usage: UsageQuota?
    var evolve: EvolveReport?
    var sshClient: SSHService?
    var projectName: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var actionFeedback: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Usage quota
                    if let usage {
                        usageSection(usage)
                        Divider()
                    }

                    // Header
                    headerSection

                    Divider()

                    // Task outline with progress
                    outlineSection

                    // NEXT task
                    if !project.nextTitle.isEmpty {
                        Divider()
                        nextSection
                    }

                    // Evolve recommendations
                    if let evolve, !evolve.recommendations.isEmpty {
                        Divider()
                        evolveSection(evolve)
                    }

                    // Notes
                    if !project.notes.isEmpty {
                        Divider()
                        notesSection
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("GTD Tracker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let feedback = actionFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.9), in: Capsule())
                        .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name)
                .font(.headline)
            HStack(spacing: 12) {
                Label(project.area, systemImage: "folder")
                Label(project.status, systemImage: "circle.fill")
                    .foregroundColor(project.status == "active" ? .green : .orange)
                if let evolve, !evolve.health.isEmpty {
                    healthBadge(evolve.health)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if !project.goal.isEmpty {
                Text(project.goal)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Outline

    private var outlineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let progress = project.outlineProgress
            HStack {
                Text("Tasks")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(progress.done)/\(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(.systemGray5))
                    if progress.total > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.green)
                            .frame(width: geo.size.width * CGFloat(progress.done) / CGFloat(progress.total))
                    }
                }
            }
            .frame(height: 6)

            ForEach(project.outline) { item in
                HStack(alignment: .top, spacing: 8) {
                    statusIcon(item.status)
                        .frame(width: 16)
                    Text(item.title)
                        .font(.subheadline)
                        .foregroundColor(item.isCurrent ? .primary : (item.status == "x" ? .secondary : .primary))
                        .strikethrough(item.status == "x", color: .secondary)
                    if item.isCurrent {
                        Text("NEXT")
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue, in: Capsule())
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - NEXT

    private var nextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Task")
                .font(.subheadline.weight(.semibold))

            Text(project.nextTitle)
                .font(.subheadline)
                .foregroundColor(.blue)

            if !project.subtasks.isEmpty {
                let done = project.subtasks.filter { $0.status == "x" }.count
                Text("Subtasks \(done)/\(project.subtasks.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(project.subtasks) { task in
                    HStack(alignment: .top, spacing: 8) {
                        statusIcon(task.status)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                                .font(.subheadline)
                                .strikethrough(task.status == "x", color: .secondary)
                                .foregroundColor(task.status == "x" ? .secondary : .primary)
                            if !task.estimate.isEmpty || !task.kind.isEmpty {
                                HStack(spacing: 8) {
                                    if !task.estimate.isEmpty {
                                        Label(task.estimate, systemImage: "clock")
                                    }
                                    if !task.kind.isEmpty {
                                        Label(task.kind, systemImage: "tag")
                                    }
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Usage

    private func usageSection(_ usage: UsageQuota) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plan Usage")
                .font(.subheadline.weight(.semibold))

            usageRow(label: "5h Window", utilization: usage.fiveHourUtil, reset: usage.fiveHourReset)
            usageRow(label: "Weekly", utilization: usage.sevenDayUtil, reset: usage.sevenDayReset)
        }
    }

    private func usageRow(label: String, utilization: Double, reset: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text("\(Int(utilization))%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundColor(utilization >= 90 ? .red : (utilization >= 70 ? .orange : .green))
                if !reset.isEmpty && reset != "-" {
                    Text("· \(reset)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(.systemGray5))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(utilization >= 90 ? Color.red : (utilization >= 70 ? Color.orange : Color.green))
                        .frame(width: geo.size.width * CGFloat(min(utilization, 100)) / 100)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Evolve Recommendations

    private func evolveSection(_ report: EvolveReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Evolve Insights")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !report.reportDate.isEmpty {
                    Text(report.reportDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Health + summary
            if !report.summary.isEmpty {
                Text(report.summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }

            // Recommendations
            ForEach(report.recommendations) { rec in
                recCard(rec)
            }
        }
    }

    private func recCard(_ rec: EvolveRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Tags row
            HStack(spacing: 6) {
                Text("\(rec.index + 1)")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.gray))

                priorityTag(rec.priority)
                typeTag(rec.type)

                Spacer()

                if let action = rec.action {
                    actionBadge(action, type: rec.actionType)
                }
            }

            // Description
            Text(rec.description)
                .font(.caption)
                .foregroundColor(rec.action != nil ? .secondary : .primary)
                .strikethrough(rec.action == "reject" || rec.action == "done")

            // Action buttons (only if not yet acted on)
            if rec.action == nil {
                HStack(spacing: 12) {
                    Button {
                        Task { await acceptRec(rec, as: "idea") }
                    } label: {
                        Label("Idea", systemImage: "lightbulb")
                            .font(.caption2)
                    }
                    .tint(.yellow)

                    Button {
                        Task { await acceptRec(rec, as: "task") }
                    } label: {
                        Label("Task", systemImage: "plus.circle")
                            .font(.caption2)
                    }
                    .tint(.blue)

                    Button {
                        Task { await markRec(rec, action: "done") }
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(.caption2)
                    }
                    .tint(.green)

                    Button {
                        Task { await markRec(rec, action: "reject") }
                    } label: {
                        Label("Skip", systemImage: "xmark")
                            .font(.caption2)
                    }
                    .tint(.gray)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(8)
    }

    // MARK: - Evolve Actions

    private func acceptRec(_ rec: EvolveRecommendation, as type: String) async {
        guard let pc = sshClient else { return }
        let desc = rec.description.replacingOccurrences(of: "'", with: "'\\''")
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withDashSeparatorInDate])

        do {
            if type == "idea" {
                // Append to 项目备忘 section
                _ = try await pc.execute("echo '- [\(today)] [evolve] \(desc)' >> ~/Projects/\(projectName)/PROJECT.md")
            } else {
                // Append to 任务大纲 - find the section and append
                _ = try await pc.execute("sed -i '' '/^## 任务大纲/a\\\n- [ ] [evolve] \(desc)' ~/Projects/\(projectName)/PROJECT.md 2>/dev/null || echo '- [ ] [evolve] \(desc)' >> ~/Projects/\(projectName)/PROJECT.md")
            }
            await writeFeedback(rec, action: "accept", actionType: type)
            showFeedback(type == "idea" ? "Added as idea" : "Added as task")
        } catch {
            showFeedback("Failed")
        }
    }

    private func markRec(_ rec: EvolveRecommendation, action: String) async {
        await writeFeedback(rec, action: action, actionType: nil)
        showFeedback(action == "done" ? "Marked done" : "Skipped")
    }

    private func writeFeedback(_ rec: EvolveRecommendation, action: String, actionType: String?) async {
        guard let pc = sshClient, let evolve else { return }
        let date = evolve.reportDate
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withDashSeparatorInDate])
        let typeField = actionType != nil ? ", \"action_type\": \"\(actionType!)\"" : ""
        let json = "{\"timestamp\": \"\(today)\", \"date\": \"\(date)\", \"module\": \"projects\", \"item_id\": \"\(projectName)\", \"insight_index\": \(rec.index), \"action\": \"\(action)\"\(typeField), \"note\": \"\"}"
        _ = try? await pc.execute("echo '\(json)' >> ~/Projects/evolve_engine/code/feedback/\(date).jsonl")
    }

    private func showFeedback(_ message: String) {
        actionFeedback = message
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            actionFeedback = nil
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.subheadline.weight(.semibold))

            ForEach(0..<project.notes.count, id: \.self) { i in
                Text(project.notes[i])
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusIcon(_ status: String) -> some View {
        switch status {
        case "x":
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        case ">":
            Image(systemName: "play.circle.fill")
                .foregroundColor(.blue)
                .font(.caption)
        case "-":
            Image(systemName: "minus.circle")
                .foregroundColor(.gray)
                .font(.caption)
        default:
            Image(systemName: "circle")
                .foregroundColor(.gray.opacity(0.5))
                .font(.caption)
        }
    }

    private func healthBadge(_ health: String) -> some View {
        let color: Color = switch health {
        case "healthy": .green
        case "needs_attention": .orange
        case "at_risk": .red
        default: .gray
        }
        return Text(health.replacingOccurrences(of: "_", with: " "))
            .font(.system(.caption2, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func priorityTag(_ priority: String) -> some View {
        let color: Color = switch priority {
        case "critical": .red
        case "high": .orange
        case "medium": .yellow
        case "low": .gray
        default: .gray
        }
        return Text(priority)
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func typeTag(_ type: String) -> some View {
        Text(type)
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color(.systemGray5), in: Capsule())
    }

    private func actionBadge(_ action: String, type: String?) -> some View {
        let label = switch action {
        case "accept": type == "idea" ? "idea" : "task"
        case "done": "done"
        case "reject": "skipped"
        default: action
        }
        let color: Color = switch action {
        case "accept": .blue
        case "done": .green
        case "reject": .gray
        default: .gray
        }
        return Text(label)
            .font(.system(.caption2, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }
}
