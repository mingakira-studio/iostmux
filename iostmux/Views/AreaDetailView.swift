import SwiftUI

struct AreaDetailView: View {
    let area: AreaRecord
    let projects: [GTDProject]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Text(area.name)
                        .font(.title2.weight(.bold))
                    Spacer()
                    Text("\(area.projectCount) projects")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Standards
                if !area.standards.isEmpty {
                    Divider()
                    Text("Standards")
                        .font(.subheadline.weight(.semibold))
                    Text(area.standards)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Goals
                if !area.goals.isEmpty {
                    Divider()
                    Text("Goals")
                        .font(.subheadline.weight(.semibold))
                    Text(area.goals)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Projects in this area
                if !projects.isEmpty {
                    Divider()
                    Text("Projects")
                        .font(.subheadline.weight(.semibold))
                    ForEach(projects) { project in
                        HStack {
                            statusDot(project.status)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                    .font(.subheadline)
                                if !project.nextTitle.isEmpty {
                                    Text(project.nextTitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            let p = project.outlineProgress
                            if p.total > 0 {
                                Text("\(p.done)/\(p.total)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Review notes
                if !area.reviewNotes.isEmpty {
                    Divider()
                    Text("Review Notes")
                        .font(.subheadline.weight(.semibold))
                    Text(area.reviewNotes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(area.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statusDot(_ status: String) -> some View {
        Circle()
            .fill(status == "active" ? Color.green : (status == "paused" ? Color.orange : Color.gray))
            .frame(width: 8, height: 8)
    }
}
