import SwiftUI

struct ProjectDetailView: View {
    let projectName: String
    @ObservedObject var ssh: SSHService
    @State private var project: GTDProject?
    @State private var evolve: EvolveReport?
    @State private var usage: UsageQuota?
    @State private var projectFiles: [(name: String, category: String)] = []
    @State private var selectedFileContent: String?
    @State private var selectedFileName: String?
    @State private var isLoading = true
    @State private var selectedTab = 0
    @State private var actionFeedback: String?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Loading...")
                Spacer()
            } else if let project {
                // Section tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        tabButton("Overview", index: 0)
                        tabButton("Tasks", index: 1)
                        tabButton("Evolve", index: 2)
                        tabButton("Files", index: 3)
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.vertical, 6)
                .background(Color(uiColor: .secondarySystemBackground))

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch selectedTab {
                        case 0: overviewSection(project)
                        case 1: tasksSection(project)
                        case 2: evolveSection
                        case 3: filesSection
                        default: EmptyView()
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
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
        .task { await loadProjectDetail() }
    }

    // MARK: - Tab Button

    private func tabButton(_ title: String, index: Int) -> some View {
        Button {
            selectedTab = index
        } label: {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(selectedTab == index ? Color.blue : Color.clear)
                .foregroundColor(selectedTab == index ? .white : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Overview

    private func overviewSection(_ project: GTDProject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Usage
            if let usage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Plan Usage")
                        .font(.subheadline.weight(.semibold))
                    usageRow("5h Window", utilization: usage.fiveHourUtil, reset: usage.fiveHourReset)
                    usageRow("Weekly", utilization: usage.sevenDayUtil, reset: usage.sevenDayReset)
                }
                Divider()
            }

            // Project info
            HStack(spacing: 12) {
                if !project.area.isEmpty {
                    Label(project.area, systemImage: "folder")
                }
                Label(project.status, systemImage: "circle.fill")
                    .foregroundColor(project.status == "active" ? .green : .orange)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if !project.goal.isEmpty {
                Text(project.goal)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Progress
            let progress = project.outlineProgress
            HStack {
                Text("Progress")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(progress.done)/\(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(.systemGray5))
                    if progress.total > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.green)
                            .frame(width: geo.size.width * CGFloat(progress.done) / CGFloat(progress.total))
                    }
                }
            }
            .frame(height: 6)

            // NEXT task
            if !project.nextTitle.isEmpty {
                Divider()
                Text("Current Task")
                    .font(.subheadline.weight(.semibold))
                Text(project.nextTitle)
                    .font(.subheadline)
                    .foregroundColor(.blue)
            }

            // Evolve health
            if let evolve, !evolve.health.isEmpty {
                Divider()
                HStack {
                    Text("Health")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(evolve.health.replacingOccurrences(of: "_", with: " "))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(healthColor(evolve.health).opacity(0.15), in: Capsule())
                        .foregroundColor(healthColor(evolve.health))
                }
                if !evolve.summary.isEmpty {
                    Text(evolve.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                }
            }
        }
    }

    // MARK: - Tasks

    private func tasksSection(_ project: GTDProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(project.outline) { item in
                HStack(alignment: .top, spacing: 8) {
                    statusIcon(item.status).frame(width: 16)
                    Text(item.title)
                        .font(.subheadline)
                        .foregroundColor(item.status == "x" ? .secondary : .primary)
                        .strikethrough(item.status == "x")
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

            if !project.subtasks.isEmpty {
                Divider()
                Text("Subtasks")
                    .font(.subheadline.weight(.semibold))
                ForEach(project.subtasks) { task in
                    HStack(alignment: .top, spacing: 8) {
                        statusIcon(task.status).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                                .font(.subheadline)
                                .strikethrough(task.status == "x")
                                .foregroundColor(task.status == "x" ? .secondary : .primary)
                            if !task.estimate.isEmpty || !task.kind.isEmpty {
                                HStack(spacing: 6) {
                                    if !task.estimate.isEmpty { Label(task.estimate, systemImage: "clock") }
                                    if !task.kind.isEmpty { Label(task.kind, systemImage: "tag") }
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

    // MARK: - Evolve

    @ViewBuilder
    private var evolveSection: some View {
        if let evolve, !evolve.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recommendations")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !evolve.reportDate.isEmpty {
                        Text(evolve.reportDate)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                ForEach(evolve.recommendations) { rec in
                    VStack(alignment: .leading, spacing: 6) {
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
                        Text(rec.description)
                            .font(.caption)
                            .foregroundColor(rec.action != nil ? .secondary : .primary)
                            .strikethrough(rec.action == "reject" || rec.action == "done")

                        if rec.action == nil {
                            HStack(spacing: 12) {
                                Button { Task { await acceptRec(rec, as: "idea") } } label: {
                                    Label("Idea", systemImage: "lightbulb").font(.caption2)
                                }.tint(.yellow)
                                Button { Task { await acceptRec(rec, as: "task") } } label: {
                                    Label("Task", systemImage: "plus.circle").font(.caption2)
                                }.tint(.blue)
                                Button { Task { await markRec(rec, action: "done") } } label: {
                                    Label("Done", systemImage: "checkmark").font(.caption2)
                                }.tint(.green)
                                Button { Task { await markRec(rec, action: "reject") } } label: {
                                    Label("Skip", systemImage: "xmark").font(.caption2)
                                }.tint(.gray)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .cornerRadius(8)
                }
            }
        } else {
            Text("No evolve report available")
                .foregroundColor(.secondary)
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Files

    @ViewBuilder
    private var filesSection: some View {
        if let content = selectedFileContent, let name = selectedFileName {
            // File preview
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        selectedFileContent = nil
                        selectedFileName = nil
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.subheadline)
                    }
                    Spacer()
                    Text(name)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                Divider()
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }
        } else if projectFiles.isEmpty {
            Text("No files found")
                .foregroundColor(.secondary)
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
        } else {
            // File list grouped by category
            let grouped = Dictionary(grouping: projectFiles, by: { $0.category })
            let order = ["PROJECT", "CLAUDE", "PLAN", "ISSUES", "DOCS", "LOG"]
            let sortedKeys = order.filter { grouped[$0] != nil } + grouped.keys.sorted().filter { !order.contains($0) }

            ForEach(sortedKeys, id: \.self) { category in
                if let files = grouped[category] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                        ForEach(0..<files.count, id: \.self) { i in
                            Button {
                                Task { await loadFileContent(files[i].name) }
                            } label: {
                                HStack {
                                    Image(systemName: fileIcon(files[i].category))
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                        .frame(width: 20)
                                    Text(files[i].name)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
        }
    }

    private func fileIcon(_ category: String) -> String {
        switch category {
        case "PROJECT": return "doc.text.fill"
        case "CLAUDE": return "cpu"
        case "PLAN": return "list.clipboard"
        case "ISSUES": return "exclamationmark.triangle"
        case "LOG": return "clock"
        case "DOCS": return "doc.richtext"
        default: return "doc"
        }
    }

    private func loadFileContent(_ name: String) async {
        do {
            let content = try await ssh.execute("cat ~/Projects/\(projectName)/\(name) 2>/dev/null | head -200")
            selectedFileName = name
            selectedFileContent = content
        } catch {}
    }

    // MARK: - Evolve Actions

    private func acceptRec(_ rec: EvolveRecommendation, as type: String) async {
        let desc = rec.description.replacingOccurrences(of: "'", with: "'\\''")
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withDashSeparatorInDate])
        do {
            if type == "idea" {
                _ = try await ssh.execute("echo '- [\(today)] [evolve] \(desc)' >> ~/Projects/\(projectName)/PROJECT.md")
            } else {
                _ = try await ssh.execute("sed -i '' '/^## 任务大纲/a\\\n- [ ] [evolve] \(desc)' ~/Projects/\(projectName)/PROJECT.md 2>/dev/null || echo '- [ ] [evolve] \(desc)' >> ~/Projects/\(projectName)/PROJECT.md")
            }
            await writeFeedback(rec, action: "accept", actionType: type)
            showFeedback(type == "idea" ? "Added as idea" : "Added as task")
        } catch {}
    }

    private func markRec(_ rec: EvolveRecommendation, action: String) async {
        await writeFeedback(rec, action: action, actionType: nil)
        showFeedback(action == "done" ? "Marked done" : "Skipped")
    }

    private func writeFeedback(_ rec: EvolveRecommendation, action: String, actionType: String?) async {
        guard let evolve else { return }
        let date = evolve.reportDate
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withDashSeparatorInDate])
        let typeField = actionType != nil ? ", \"action_type\": \"\(actionType!)\"" : ""
        let json = "{\"timestamp\": \"\(today)\", \"date\": \"\(date)\", \"module\": \"projects\", \"item_id\": \"\(projectName)\", \"insight_index\": \(rec.index), \"action\": \"\(action)\"\(typeField), \"note\": \"\"}"
        _ = try? await ssh.execute("echo '\(json)' >> ~/Projects/evolve_engine/code/feedback/\(date).jsonl")
    }

    private func showFeedback(_ msg: String) {
        actionFeedback = msg
        Task { try? await Task.sleep(for: .seconds(1.5)); actionFeedback = nil }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusIcon(_ status: String) -> some View {
        switch status {
        case "x": Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
        case ">": Image(systemName: "play.circle.fill").foregroundColor(.blue).font(.caption)
        case "-": Image(systemName: "minus.circle").foregroundColor(.gray).font(.caption)
        default: Image(systemName: "circle").foregroundColor(.gray.opacity(0.5)).font(.caption)
        }
    }

    private func healthColor(_ health: String) -> Color {
        switch health {
        case "healthy": .green
        case "needs_attention": .orange
        case "at_risk": .red
        default: .gray
        }
    }

    private func priorityTag(_ p: String) -> some View {
        let c: Color = switch p { case "critical": .red; case "high": .orange; case "medium": .yellow; default: .gray }
        return Text(p).font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundColor(c).padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.15), in: Capsule())
    }

    private func typeTag(_ t: String) -> some View {
        Text(t).font(.system(.caption2, design: .monospaced))
            .foregroundColor(.secondary).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color(.systemGray5), in: Capsule())
    }

    private func actionBadge(_ action: String, type: String?) -> some View {
        let label = switch action { case "accept": type == "idea" ? "idea" : "task"; case "done": "done"; case "reject": "skipped"; default: action }
        let c: Color = switch action { case "accept": .blue; case "done": .green; default: .gray }
        return Text(label).font(.system(.caption2, weight: .medium))
            .foregroundColor(c).padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.15), in: Capsule())
    }

    private func usageRow(_ label: String, utilization: Double, reset: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(Int(utilization))%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundColor(utilization >= 90 ? .red : (utilization >= 70 ? .orange : .green))
                if !reset.isEmpty && reset != "-" {
                    Text("· \(reset)").font(.caption2).foregroundColor(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(.systemGray5))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(utilization >= 90 ? Color.red : (utilization >= 70 ? Color.orange : Color.green))
                        .frame(width: geo.size.width * CGFloat(min(utilization, 100)) / 100)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Load Data

    private func loadProjectDetail() async {
        do {
            try await ssh.ensureConnected()

            let content = try await ssh.execute("cat ~/Projects/\(projectName)/PROJECT.md 2>/dev/null || echo ''")
            if !content.isEmpty { project = GTDParser.parse(content) }

            let usageJson = try await ssh.execute("cat ~/.claude/.cache/usage_default__api_oauth_usage.json 2>/dev/null || echo ''")
            usage = UsageParser.parse(usageJson)

            let reportPath = try await ssh.execute("ls -t ~/Projects/evolve_engine/code/output/*/projects/\(projectName).json 2>/dev/null | head -1")
            let rpClean = reportPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rpClean.isEmpty && !rpClean.contains("No such file") {
                let reportJson = try await ssh.execute("cat '\(rpClean)' 2>/dev/null || echo ''")
                if var report = EvolveParser.parse(reportJson) {
                    let parts = rpClean.components(separatedBy: "/")
                    if let idx = parts.firstIndex(of: "output"), idx + 1 < parts.count {
                        report.reportDate = parts[idx + 1]
                    }
                    if !report.reportDate.isEmpty {
                        let fb = try await ssh.execute("cat ~/Projects/evolve_engine/code/feedback/\(report.reportDate).jsonl 2>/dev/null || echo ''")
                        EvolveParser.applyFeedback(fb, to: &report, projectId: projectName)
                    }
                    evolve = report
                }
            }

            // Discover project files (markdown docs)
            let fileList = try await ssh.execute("""
                cd ~/Projects/\(projectName) && find . -maxdepth 3 -name '*.md' \
                    -not -path './.git/*' -not -path './node_modules/*' \
                    -not -path './.build/*' -not -path './DerivedData/*' \
                    -not -path './__pycache__/*' -not -path './venv/*' \
                    2>/dev/null | sort
                """)
            projectFiles = fileList.split(separator: "\n").compactMap { line in
                let name = String(line).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "./", with: "")
                guard !name.isEmpty else { return nil }
                let category: String
                if name == "PROJECT.md" { category = "PROJECT" }
                else if name == "CLAUDE.md" { category = "CLAUDE" }
                else if name == "PLAN.md" || name.hasPrefix("plan/") { category = "PLAN" }
                else if name == "ISSUES.md" { category = "ISSUES" }
                else if name == "LOG.md" { category = "LOG" }
                else { category = "DOCS" }
                return (name: name, category: category)
            }
        } catch {}
        isLoading = false
    }
}
