import SwiftUI

struct DashboardTab: View {
    @ObservedObject var ssh: SSHService
    @State private var projects: [GTDProject] = []
    @State private var areas: [AreaRecord] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selectedSection = 0  // 0=Projects, 1=Areas
    @State private var searchText = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Section picker
                Picker("Section", selection: $selectedSection) {
                    Text("Projects").tag(0)
                    Text("Areas").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if isLoading {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                } else if let error {
                    Spacer()
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    HStack(spacing: 16) {
                        Button("Open Tailscale") {
                            if let url = URL(string: "tailscale://") {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        Button("Retry") { Task { await loadDashboard() } }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else if selectedSection == 0 {
                    projectsList
                } else {
                    areasList
                }
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search")
            .navigationDestination(for: DashboardDestination.self) { dest in
                switch dest {
                case .project(let name):
                    ProjectDetailView(projectName: name, ssh: ssh)
                case .area(let name):
                    let areaProjects = projects.filter { $0.area == name }
                    AreaDetailView(area: areas.first(where: { $0.name == name }) ?? AreaRecord(name: name), projects: areaProjects)
                }
            }
        }
        .task { await loadDashboard() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await loadDashboard() } }
        }
    }

    // MARK: - Projects List

    private var projectsList: some View {
        List(sortedProjects) { project in
            NavigationLink(value: DashboardDestination.project(project.dirName)) {
                dashboardProjectRow(project)
            }
        }
        .refreshable { await loadDashboard() }
    }

    private var sortedProjects: [GTDProject] {
        let filtered = searchText.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return filtered.sorted { a, b in
            let aOrder = a.status == "active" ? 0 : (a.status == "paused" ? 1 : 2)
            let bOrder = b.status == "active" ? 0 : (b.status == "paused" ? 1 : 2)
            if aOrder != bOrder { return aOrder < bOrder }
            return a.name < b.name
        }
    }

    private var filteredAreas: [AreaRecord] {
        searchText.isEmpty ? areas : areas.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func dashboardProjectRow(_ project: GTDProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                statusBadge(project.status)
            }

            // Progress bar
            let progress = project.outlineProgress
            if progress.total > 0 {
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(.systemGray5))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.green)
                                .frame(width: geo.size.width * CGFloat(progress.done) / CGFloat(progress.total))
                        }
                    }
                    .frame(height: 4)
                    Text("\(progress.done)/\(progress.total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 35, alignment: .trailing)
                }
            }

            // NEXT task + area
            HStack {
                if !project.area.isEmpty {
                    Text(project.area)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(.systemGray5))
                        .cornerRadius(4)
                }
                if !project.nextTitle.isEmpty {
                    Text(project.nextTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Areas List

    private var areasList: some View {
        List(filteredAreas) { area in
            NavigationLink(value: DashboardDestination.area(area.name)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(area.name)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(area.projectCount) projects")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if !area.goals.isEmpty {
                        Text(area.goals)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .refreshable { await loadDashboard() }
    }

    // MARK: - Helpers

    private func statusBadge(_ status: String) -> some View {
        let color: Color = switch status {
        case "active": .green
        case "paused": .orange
        case "completed": .blue
        default: .gray
        }
        return Text(status)
            .font(.system(.caption2, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: - Data

    private func loadDashboard() async {
        isLoading = projects.isEmpty && areas.isEmpty
        error = nil
        do {
            try await ssh.ensureConnected()

            // Fetch all PROJECT.md files in one batch
            let dirs = try await ssh.execute("ls -1 ~/Projects")
            let projectNames = dirs.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // Batch read PROJECT.md files
            let batchCmd = projectNames.map { name in
                "echo 'PROJ_START:\(name)'; cat ~/Projects/\(name)/PROJECT.md 2>/dev/null; echo 'PROJ_END:\(name)'"
            }.joined(separator: "; ")
            let batchOutput = try await ssh.execute(batchCmd)

            var parsed: [GTDProject] = []
            var current = ""
            var lines: [String] = []

            for line in batchOutput.components(separatedBy: "\n") {
                if line.hasPrefix("PROJ_START:") {
                    current = String(line.dropFirst(11))
                    lines = []
                } else if line.hasPrefix("PROJ_END:") {
                    if !current.isEmpty && !lines.isEmpty {
                        let content = lines.joined(separator: "\n")
                        var proj = GTDParser.parse(content)
                        proj.dirName = current  // directory name
                        if proj.name.isEmpty { proj.name = current }
                        parsed.append(proj)
                    }
                    current = ""
                } else if !current.isEmpty {
                    lines.append(line)
                }
            }
            projects = parsed

            // Fetch area files
            let areaFiles = try await ssh.execute("ls -1 ~/workspace/gtd/areas/*.md 2>/dev/null || echo ''")
            let areaNames = areaFiles.split(separator: "\n")
                .compactMap { path -> String? in
                    let name = String(path).components(separatedBy: "/").last?.replacingOccurrences(of: ".md", with: "")
                    return name?.isEmpty == false ? name : nil
                }

            if !areaNames.isEmpty {
                let areaBatch = areaNames.map { name in
                    "echo 'AREA_START:\(name)'; cat ~/workspace/gtd/areas/\(name).md 2>/dev/null; echo 'AREA_END:\(name)'"
                }.joined(separator: "; ")
                let areaOutput = try await ssh.execute(areaBatch)

                var parsedAreas: [AreaRecord] = []
                var currentArea = ""
                var areaLines: [String] = []

                for line in areaOutput.components(separatedBy: "\n") {
                    if line.hasPrefix("AREA_START:") {
                        currentArea = String(line.dropFirst(11))
                        areaLines = []
                    } else if line.hasPrefix("AREA_END:") {
                        if !currentArea.isEmpty {
                            let content = areaLines.joined(separator: "\n")
                            var area = AreaParser.parse(content, name: currentArea)
                            area.projectCount = parsed.filter { $0.area == currentArea }.count
                            parsedAreas.append(area)
                        }
                        currentArea = ""
                    } else if !currentArea.isEmpty {
                        areaLines.append(line)
                    }
                }
                areas = parsedAreas.sorted { $0.projectCount > $1.projectCount }
            }
        } catch {
            do {
                try? await ssh.close()
                try await ssh.connect()
                // Don't retry full load to avoid recursion — just set error
            } catch {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }
}

// MARK: - Navigation

enum DashboardDestination: Hashable {
    case project(String)
    case area(String)
}
