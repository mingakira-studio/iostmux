import Foundation
import Citadel
import Crypto
import NIO
import NIOSSH

@MainActor
class SSHService: ObservableObject {
    private var client: SSHClient?
    @Published var isConnected = false

    nonisolated(unsafe) private var _ttyWriter: TTYStdinWriter?

    enum ConnectionState {
        case connected, disconnected, reconnecting(attempt: Int)
    }
    @Published var connectionState: ConnectionState = .disconnected
    @Published var shellError: String?
    @Published var debugStatus: String = ""
    @Published var dataReceived: Int = 0

    private func authMethod() throws -> SSHAuthenticationMethod {
        guard let keyData = KeychainHelper.loadPrivateKey() else {
            throw SSHError.noKey
        }
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyData)
        return .ed25519(username: Config.sshUser, privateKey: privateKey)
    }

    func connect() async throws {
        let auth = try authMethod()
        client = try await SSHClient.connect(
            host: Config.sshHost,
            port: Int(Config.sshPort),
            authenticationMethod: auth,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        isConnected = true
        connectionState = .connected
    }

    func reconnect(project: String, onData: @escaping @Sendable (Data) -> Void) async {
        for attempt in 1...3 {
            connectionState = .reconnecting(attempt: attempt)
            try? await Task.sleep(for: .seconds(2))
            do {
                try await connect()
                openShell(project: project, cols: 80, rows: 24, onData: onData)
                connectionState = .connected
                return
            } catch {
                if attempt == 3 {
                    connectionState = .disconnected
                }
            }
        }
    }

    func execute(_ command: String) async throws -> String {
        guard let client else { throw SSHError.notConnected }
        let output = try await client.executeCommand(command, inShell: true)
        return String(buffer: output)
    }

    func fetchProjects() async throws -> [Project] {
        let dirs = try await execute("ls -1 \(Config.projectsPath)")
        let sessions = try await execute(
            "tmux list-sessions -F '#{session_name}' 2>/dev/null || true"
        )
        let sessionSet = Set(sessions.split(separator: "\n").map(String.init))
        return dirs.split(separator: "\n")
            .map { name in
                let n = String(name).trimmingCharacters(in: .whitespacesAndNewlines)
                return Project(name: n, hasActiveSession: sessionSet.contains(n))
            }
            .filter { !$0.name.isEmpty }
            .sorted()
    }

    /// Open interactive PTY shell for a tmux session.
    func openShell(
        project: String,
        cols: Int = 80,
        rows: Int = 24,
        onData: @escaping @Sendable (Data) -> Void
    ) {
        guard let client else {
            shellError = "No SSH client"
            return
        }
        shellError = nil
        dataReceived = 0
        debugStatus = "Opening PTY..."

        Task.detached { [weak self] in
            do {
                // Kill extra panes BEFORE opening PTY (keeps only pane 1 = Claude Code)
                await MainActor.run { self?.debugStatus = "Cleaning panes..." }
                _ = try? await client.executeCommand("tmux kill-pane -a -t '\(project):.1' 2>/dev/null || true", inShell: true)

                await MainActor.run { self?.debugStatus = "withPTY \(cols)x\(rows)..." }
                let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:])
                )
                try await client.withPTY(ptyRequest) { ttyOutput, ttyStdinWriter in
                    await MainActor.run {
                        self?._ttyWriter = ttyStdinWriter
                        self?.debugStatus = "PTY connected"
                    }

                    // Start reading output
                    let readTask = Task {
                        for try await output in ttyOutput {
                            switch output {
                            case .stdout(let buffer):
                                let data = Data(buffer: buffer)
                                await MainActor.run { self?.dataReceived += data.count }
                                onData(data)
                            case .stderr(let buffer):
                                let data = Data(buffer: buffer)
                                await MainActor.run { self?.dataReceived += data.count }
                                onData(data)
                            }
                        }
                    }

                    // Wait for shell prompt, then attach tmux
                    try await Task.sleep(for: .milliseconds(300))
                    await MainActor.run { self?.debugStatus = "Attaching tmux..." }
                    let cmd = "tmux attach-session -t \(project) 2>/dev/null || (cd ~/Projects/\(project) && ccc)\n"
                    try await ttyStdinWriter.write(ByteBuffer(string: cmd))

                    try await readTask.value
                }
                await MainActor.run { self?.debugStatus = "PTY closed" }
            } catch {
                await MainActor.run {
                    self?.shellError = "Shell: \(error)"
                    self?.debugStatus = "Error: \(error)"
                }
            }
        }
    }

    func send(_ text: String) async throws {
        guard let writer = _ttyWriter else { throw SSHError.noActiveShell }
        try await writer.write(ByteBuffer(string: text))
    }

    func sendBytes(_ bytes: [UInt8]) async throws {
        guard let writer = _ttyWriter else { throw SSHError.noActiveShell }
        try await writer.write(ByteBuffer(bytes: bytes))
    }

    func sendWindowChange(cols: Int, rows: Int) async throws {
        guard let writer = _ttyWriter else { throw SSHError.noActiveShell }
        try await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    /// Close shell and SSH connection (withPTY invalidates the connection)
    func closeShell() {
        _ttyWriter = nil
        // Must close full connection — NIOSSH can't reuse after withPTY ends
        Task {
            try? await client?.close()
            client = nil
            isConnected = false
            debugStatus = "Shell closed"
        }
    }

    /// Close entire SSH connection
    func close() async throws {
        _ttyWriter = nil
        try await client?.close()
        client = nil
        isConnected = false
        connectionState = .disconnected
    }

    /// Ensure SSH client is connected, reconnect if needed
    func ensureConnected() async throws {
        if client == nil || !isConnected {
            try await connect()
        }
    }
}

enum SSHError: LocalizedError {
    case notConnected
    case noActiveShell
    case noKey

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to SSH server"
        case .noActiveShell: return "No active shell session"
        case .noKey: return "No SSH key configured"
        }
    }
}
