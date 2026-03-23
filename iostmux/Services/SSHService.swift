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
            "tmux list-sessions -F '#{session_name} #{session_activity}' 2>/dev/null || true"
        )
        var sessionSet = Set<String>()
        var activityMap: [String: Int] = [:]
        for line in sessions.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            let name = String(parts[0])
            sessionSet.insert(name)
            if parts.count > 1, let ts = Int(parts[1]) {
                activityMap[name] = ts
            }
        }

        // Detect idle vs active by comparing two captures 1s apart (content change = active)
        var stateMap: [String: SessionState] = [:]
        if !sessionSet.isEmpty {
            // Run all comparisons in parallel using background subshells
            let cmd = sessionSet.sorted().map { name in
                "( h1=$(tmux capture-pane -t '\(name)' -p 2>/dev/null | md5); sleep 1; h2=$(tmux capture-pane -t '\(name)' -p 2>/dev/null | md5); if [ \"$h1\" = \"$h2\" ]; then echo 'SESSION:\(name):idle'; else echo 'SESSION:\(name):active'; fi ) &"
            }.joined(separator: " ") + " wait"
            let output = try await execute(cmd)

            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("SESSION:") {
                    let parts = line.dropFirst(8).split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let name = String(parts[0])
                        let state = String(parts[1])
                        stateMap[name] = state == "active" ? .active : .idle
                    }
                }
            }
        }

        // Batch extract area + last updated from PROJECT.md files
        let projectNames = dirs.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var metaMap: [String: (area: String, updated: String)] = [:]
        if !projectNames.isEmpty {
            let metaCmd = projectNames.map { name in
                "echo 'META:\(name):'; head -20 ~/Projects/\(name)/PROJECT.md 2>/dev/null | grep -E '(Area|Last Updated|Status)' || echo ''"
            }.joined(separator: "; ")
            let metaOutput = try await execute(metaCmd)

            var currentName = ""
            var area = ""
            var updated = ""
            for line in metaOutput.components(separatedBy: "\n") {
                if line.hasPrefix("META:") && line.hasSuffix(":") {
                    if !currentName.isEmpty {
                        metaMap[currentName] = (area, updated)
                    }
                    currentName = String(line.dropFirst(5).dropLast(1))
                    area = ""
                    updated = ""
                } else {
                    let clean = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
                    if clean.contains("Area:") {
                        area = clean.components(separatedBy: "Area:").last?.trimmingCharacters(in: .whitespaces) ?? ""
                    }
                    if clean.contains("Last Updated:") {
                        updated = clean.components(separatedBy: "Last Updated:").last?.trimmingCharacters(in: .whitespaces) ?? ""
                    }
                }
            }
            if !currentName.isEmpty {
                metaMap[currentName] = (area, updated)
            }
        }

        let projectNameSet = Set(projectNames)
        var allProjects = projectNames
            .map { name in
                let hasSession = sessionSet.contains(name)
                let meta = metaMap[name]
                return Project(
                    name: name,
                    hasActiveSession: hasSession,
                    sessionState: stateMap[name] ?? (hasSession ? .idle : .none),
                    area: meta?.area ?? "",
                    lastUpdated: meta?.updated ?? "",
                    lastActivity: activityMap[name] ?? 0
                )
            }

        // Add tmux sessions that don't match a project directory (e.g. general-0)
        for sessionName in sessionSet {
            if !projectNameSet.contains(sessionName) {
                allProjects.append(Project(
                    name: sessionName,
                    hasActiveSession: true,
                    sessionState: stateMap[sessionName] ?? .idle,
                    area: "session",
                    lastActivity: activityMap[sessionName] ?? 0
                ))
            }
        }

        return allProjects.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
                if $0.lastUpdated != $1.lastUpdated { return $0.lastUpdated > $1.lastUpdated }
                return $0.name < $1.name
            }
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

    /// Upload file via SFTP
    func uploadFile(data: Data, remotePath: String) async throws {
        guard let client else { throw SSHError.notConnected }
        // Ensure directory exists
        let dir = (remotePath as NSString).deletingLastPathComponent
        _ = try? await client.executeCommand("mkdir -p '\(dir)'", inShell: true)

        try await client.withSFTP { sftp in
            let file = try await sftp.openFile(filePath: remotePath, flags: [.create, .write, .truncate])
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            try await file.write(buffer)
            try await file.close()
        }
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
