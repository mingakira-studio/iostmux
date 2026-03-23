import SwiftUI

struct SessionsTab: View {
    @ObservedObject var ssh: SSHService
    @State private var projects: [Project] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var selectedArea: String? = nil
    @State private var searchText = ""
    @State private var previouslyWorking: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "previouslyWorking") ?? [])
    @State private var viewedSessions: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "viewedSessions") ?? [])
    @State private var showNewProject = false
    @State private var newProjectName = ""
    @State private var newProjectArea = "coding"
    @State private var navigateToProject: String?
    @State private var showSearch = false
    @State private var savedActivity: [String: Int] = [:]  // activity before entering session
    @Environment(\.scenePhase) private var scenePhase

    private var areas: [String] {
        Array(Set(projects.compactMap { $0.area.isEmpty ? nil : $0.area })).sorted()
    }

    private var filteredProjects: [Project] {
        var result = projects
        if let area = selectedArea {
            result = result.filter { $0.area == area }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Connecting...")
                } else if let error {
                    VStack(spacing: 16) {
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
                            Button("Retry") { Task { await loadProjects() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        // Search bar
                        if showSearch {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.secondary)
                                TextField("Search projects", text: $searchText)
                                    .autocorrectionDisabled()
                                if !searchText.isEmpty {
                                    Button { searchText = "" } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(8)
                            .background(Color(.systemGray5))
                            .cornerRadius(8)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                        }

                        if !areas.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    filterChip("All", isSelected: selectedArea == nil) {
                                        selectedArea = nil
                                    }
                                    ForEach(areas, id: \.self) { area in
                                        filterChip(area, isSelected: selectedArea == area) {
                                            selectedArea = area
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .background(Color(uiColor: .systemGroupedBackground))
                        }

                        List(filteredProjects) { project in
                            NavigationLink(value: project.name) {
                                projectRow(project)
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                viewedSessions.insert(project.name)
                                persistState()
                                if project.lastActivity > 0 {
                                    savedActivity[project.name] = project.lastActivity
                                }
                            })
                        }
                        .refreshable { await loadProjects() }
                        .onAppear { startPolling() }
                        .onDisappear { pollTask?.cancel(); pollTask = nil }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button { withAnimation { showSearch.toggle() } } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        Button { showNewProject = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .alert("New Project", isPresented: $showNewProject) {
                TextField("project_name", text: $newProjectName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Create") {
                    let name = newProjectName.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: " ", with: "_")
                    guard !name.isEmpty else { return }
                    Task { await createProject(name: name) }
                    newProjectName = ""
                }
                Button("Cancel", role: .cancel) { newProjectName = "" }
            } message: {
                Text("Enter project directory name")
            }
            .navigationDestination(for: String.self) { projectName in
                SessionView(projectName: projectName, ssh: ssh)
            }
            .navigationDestination(isPresented: Binding(
                get: { navigateToProject != nil },
                set: { if !$0 { navigateToProject = nil } }
            )) {
                if let name = navigateToProject {
                    SessionView(projectName: name, ssh: ssh)
                }
            }
        }
        .task { await loadProjects() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await loadProjects() }
            }
        }
    }

    // MARK: - Project Row

    private func projectRow(_ project: Project) -> some View {
        HStack {
            Circle()
                .fill(project.hasActiveSession ? .green : .gray.opacity(0.3))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                HStack(spacing: 6) {
                    if !project.area.isEmpty {
                        Text(project.area)
                    }
                    if project.lastActivity > 0 {
                        Text(timeAgo(project.lastActivity))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            Spacer()
            if project.hasActiveSession {
                sessionStateLabel(project.sessionState)
            }
        }
    }

    private func timeAgo(_ timestamp: Int) -> String {
        let seconds = Int(Date().timeIntervalSince1970) - timestamp
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    // MARK: - Filter Chip

    private func filterChip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Session State

    @ViewBuilder
    private func sessionStateLabel(_ state: SessionState) -> some View {
        switch state {
        case .active:
            HStack(spacing: 4) {
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text("working")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        case .done:
            HStack(spacing: 4) {
                Circle().fill(.purple).frame(width: 6, height: 6)
                Text("done")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.purple)
            }
        case .idle:
            HStack(spacing: 4) {
                Circle().fill(.blue.opacity(0.6)).frame(width: 6, height: 6)
                Text("idle")
                    .font(.caption2)
                    .foregroundColor(.blue.opacity(0.6))
            }
        case .none:
            EmptyView()
        }
    }

    // MARK: - Data

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await loadProjects()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func loadProjects() async {
        isLoading = projects.isEmpty
        error = nil
        do {
            try await ssh.ensureConnected()
            var fetched = try await ssh.fetchProjects()
            applyDoneState(&fetched)
            projects = fetched
        } catch {
            do {
                try? await ssh.close()
                try await ssh.connect()
                var fetched = try await ssh.fetchProjects()
                applyDoneState(&fetched)
                projects = fetched
            } catch {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    /// Create new project: mkdir + tmux session + run /project-new
    private func createProject(name: String) async {
        do {
            try await ssh.ensureConnected()
            // Create directory
            _ = try await ssh.execute("mkdir -p ~/Projects/\(name)")
            // Create tmux session and run claude with /project-new
            _ = try await ssh.execute("tmux new-session -d -s '\(name)' -c ~/Projects/\(name) 'claude' 2>/dev/null || true")
            // Wait a moment for claude to start, then send /project-new
            try await Task.sleep(for: .seconds(2))
            _ = try await ssh.execute("tmux send-keys -t '\(name)' '/project-new' Enter 2>/dev/null || true")
            // Navigate to the new session
            navigateToProject = name
            // Refresh list
            await loadProjects()
        } catch {}
    }

    /// Detect working→idle transitions and mark as .done until viewed.
    /// Also restore saved activity timestamps for view-only sessions.
    private func applyDoneState(_ projects: inout [Project]) {
        var currentlyWorking = Set<String>()
        for i in projects.indices {
            let name = projects[i].name
            if projects[i].sessionState == .active {
                currentlyWorking.insert(name)
            } else if projects[i].sessionState == .idle
                        && previouslyWorking.contains(name)
                        && !viewedSessions.contains(name) {
                projects[i].sessionState = .done
            }

            // Restore pre-entry activity if user only viewed (didn't send input)
            if let saved = savedActivity[name] {
                let current = projects[i].lastActivity
                // If activity changed by less than 30s from saved, it was just an attach — restore
                if current > 0 && abs(current - saved) < 30 {
                    projects[i].lastActivity = saved
                } else {
                    // Real activity happened, clear saved
                    savedActivity.removeValue(forKey: name)
                }
            }
        }
        previouslyWorking = currentlyWorking
        // Clear viewed sessions that are now working again
        for name in currentlyWorking {
            viewedSessions.remove(name)
        }
        persistState()
    }

    private func persistState() {
        UserDefaults.standard.set(Array(previouslyWorking), forKey: "previouslyWorking")
        UserDefaults.standard.set(Array(viewedSessions), forKey: "viewedSessions")
    }
}
