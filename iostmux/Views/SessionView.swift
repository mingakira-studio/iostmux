import SwiftUI
import SwiftTerm

struct SessionView: View {
    let projectName: String
    @ObservedObject var ssh: SSHService

    @State private var terminalView: TerminalView?
    @State private var isCompactMode = true
    @State private var isConnecting = true
    @State private var connectionError: String?
    @State private var filter = OutputFilter()
    @State private var compactLines: [String] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isConnecting {
                ProgressView("Attaching to \(projectName)...")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else if let error = connectionError {
                VStack(spacing: 16) {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { Task { await connect() } }
                    Button("Back") { dismiss() }
                }
            } else {
                // Dual-buffer: both views always present, toggle visibility
                ZStack {
                    // Raw terminal — always alive
                    TerminalViewWrapper(
                        onTerminalCreated: { tv in self.terminalView = tv },
                        onUserInput: { bytes in
                            Task { try? await ssh.sendBytes(bytes) }
                        },
                        onSizeChanged: { cols, rows in
                            Task { try? await ssh.sendWindowChange(cols: cols, rows: rows) }
                        }
                    )
                    .opacity(isCompactMode ? 0 : 1)

                    // Compact filtered view
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(compactLines.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(.system(.body, design: .default))
                                        .foregroundStyle(.primary)
                                        .id(idx)
                                }
                            }
                            .padding()
                        }
                        .onChange(of: compactLines.count) { _, newCount in
                            if newCount > 0 {
                                proxy.scrollTo(newCount - 1, anchor: .bottom)
                            }
                        }
                    }
                    .opacity(isCompactMode ? 1 : 0)
                }
            }
        }
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isCompactMode ? "Raw" : "Compact") {
                    isCompactMode.toggle()
                }
                .font(.caption)
            }
        }
        .task { await connect() }
        .onDisappear {
            Task { try? await ssh.close() }
        }
    }

    private func connect() async {
        isConnecting = true
        connectionError = nil
        ssh.openShell(project: projectName) { data in
            DispatchQueue.main.async {
                // Always feed raw terminal
                let bytes = [UInt8](data)
                terminalView?.feed(byteArray: ArraySlice(bytes))

                // Also filter for compact view
                let text = String(data: data, encoding: .utf8) ?? ""
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for line in lines {
                    if filter.shouldShow(line: String(line)) {
                        compactLines.append(filter.stripANSI(String(line)))
                        if compactLines.count > 500 {
                            compactLines.removeFirst(100)
                        }
                    }
                }
            }
        }
        isConnecting = false
    }
}
