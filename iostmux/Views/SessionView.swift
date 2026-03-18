import SwiftUI
import SwiftTerm

struct SessionView: View {
    let projectName: String
    @ObservedObject var ssh: SSHService

    @State private var terminalView: TerminalView?
    @State private var isCompactMode = false
    @State private var isConnecting = true
    @State private var connectionError: String?
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
                TerminalViewWrapper(
                    onTerminalCreated: { tv in self.terminalView = tv },
                    onUserInput: { bytes in
                        Task { try? await ssh.sendBytes(bytes) }
                    },
                    onSizeChanged: { cols, rows in
                        Task { try? await ssh.sendWindowChange(cols: cols, rows: rows) }
                    }
                )
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
        do {
            ssh.openShell(project: projectName) { data in
                DispatchQueue.main.async {
                    let bytes = [UInt8](data)
                    terminalView?.feed(byteArray: ArraySlice(bytes))
                }
            }
            isConnecting = false
        }
    }
}
