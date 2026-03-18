import Foundation
import Citadel
import Crypto
import NIO

@MainActor
class SSHService: ObservableObject {
    private var client: SSHClient?
    @Published var isConnected = false

    // Shell state — set during openShell, used by send/sendBytes
    nonisolated(unsafe) private var _ttyWriter: TTYStdinWriter?

    /// Build authentication method from stored key
    private func authMethod() throws -> SSHAuthenticationMethod {
        guard let keyData = KeychainHelper.loadPrivateKey() else {
            throw SSHError.noKey
        }
        // Try Ed25519 first (most common modern key type)
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyData)
        return .ed25519(username: Config.sshUser, privateKey: privateKey)
    }

    /// Connect to the SSH server
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
    }

    /// Execute a single command, return output as string
    func execute(_ command: String) async throws -> String {
        guard let client else { throw SSHError.notConnected }
        let output = try await client.executeCommand(command, inShell: true)
        return String(buffer: output)
    }

    /// Fetch project list with tmux session status
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

    /// Open interactive TTY shell for a tmux session.
    /// This runs in a background Task — the closure streams data until the shell closes.
    func openShell(
        project: String,
        onData: @escaping @Sendable (Data) -> Void
    ) {
        guard let client else { return }
        Task.detached { [weak self] in
            try await client.withTTY { ttyOutput, ttyStdinWriter in
                // Store writer for send/sendBytes
                await MainActor.run {
                    self?._ttyWriter = ttyStdinWriter
                }

                // Send the tmux attach-or-create command
                let cmd = "tmux attach-session -t \(project) 2>/dev/null || (cd ~/Projects/\(project) && ccc)\n"
                try await ttyStdinWriter.write(ByteBuffer(string: cmd))

                // Stream output back to caller
                for try await output in ttyOutput {
                    switch output {
                    case .stdout(let buffer):
                        onData(Data(buffer: buffer))
                    case .stderr(let buffer):
                        onData(Data(buffer: buffer))
                    }
                }
            }
        }
    }

    /// Send text to the active shell
    func send(_ text: String) async throws {
        guard let writer = _ttyWriter else { throw SSHError.noActiveShell }
        try await writer.write(ByteBuffer(string: text))
    }

    /// Send raw bytes (for escape sequences like arrow keys)
    func sendBytes(_ bytes: [UInt8]) async throws {
        guard let writer = _ttyWriter else { throw SSHError.noActiveShell }
        try await writer.write(ByteBuffer(bytes: bytes))
    }

    /// Change terminal size
    func sendWindowChange(cols: Int, rows: Int) async throws {
        guard let writer = _ttyWriter else { throw SSHError.noActiveShell }
        try await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    /// Close the SSH connection
    func close() async throws {
        _ttyWriter = nil
        try await client?.close()
        client = nil
        isConnected = false
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
