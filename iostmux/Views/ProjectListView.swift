import SwiftUI

struct ProjectListView: View {
    @StateObject private var ssh = SSHService()
    @State private var projects: [Project] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Connecting...")
                } else if let error {
                    VStack(spacing: 16) {
                        Text(error)
                            .foregroundStyle(.secondary)
                        Button("Retry") { Task { await loadProjects() } }
                    }
                } else {
                    List(projects) { project in
                        NavigationLink(value: project.name) {
                            HStack {
                                Circle()
                                    .fill(project.hasActiveSession ? .green : .gray.opacity(0.3))
                                    .frame(width: 8, height: 8)
                                Text(project.name)
                            }
                        }
                    }
                    .refreshable { await loadProjects() }
                }
            }
            .navigationTitle("Projects")
            .navigationDestination(for: String.self) { projectName in
                SessionView(projectName: projectName, ssh: ssh)
            }
        }
        .task { await loadProjects() }
    }

    private func loadProjects() async {
        isLoading = projects.isEmpty
        error = nil
        do {
            try await ssh.connect()
            projects = try await ssh.fetchProjects()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
