import SwiftUI
import SwiftTerm

struct SessionView: View {
    let projectName: String
    @ObservedObject var ssh: SSHService

    @State private var terminalView: TerminalView?
    @State private var connectionError: String?
    @State private var filter = OutputFilter()
    @State private var compactLines: [FilteredLine] = []
    @State private var shellStarted = false
    @State private var pollingTask: Task<Void, Never>?

    // Cache key for this session
    private var cacheKey: String { "compactCache_\(projectName)" }
    @State private var claudeStatus: ClaudeStatus?
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.ignoresSafeArea()

                if let shellError = ssh.shellError {
                    VStack(spacing: 16) {
                        Text(shellError)
                            .foregroundStyle(.red)
                            .padding()
                        Button("Back") { dismiss() }
                    }
                } else {
                    // Hidden TerminalView — only exists to keep PTY alive
                    TerminalViewWrapper(
                        onTerminalCreated: { tv in self.terminalView = tv },
                        onUserInput: { _ in },
                        onSizeChanged: { _, _ in }
                    )
                    .frame(width: 1, height: 1)
                    .opacity(0)

                    // Compact filtered view
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(compactLines) { line in
                                    compactLineView(line).id(line.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 16)
                        }
                        .background(Color.black)
                        .onChange(of: compactLines.count) { _, _ in
                            if let last = compactLines.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            // Bottom input bar
            if ssh.shellError == nil {
                inputBar
            }
        }
        // Status bar overlay (top)
        .overlay(alignment: .top) {
            if let s = claudeStatus {
                HStack(spacing: 6) {
                    let dir = s.workDir.components(separatedBy: "/").last ?? s.workDir
                    Text(dir)
                        .foregroundColor(.white.opacity(0.7))
                    Text("·")
                        .foregroundColor(.gray)
                    Text(s.model)
                        .foregroundColor(.white.opacity(0.5))
                    Text("·")
                        .foregroundColor(.gray)
                    Text("\(s.contextUsage)%")
                        .foregroundColor(s.contextUsage > 80 ? .orange : .white.opacity(0.5))
                }
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(white: 0.1).opacity(0.95))
                .cornerRadius(6)
                .padding(.top, 2)
            }
        }
        // Reconnect banner
        .overlay(alignment: .top) {
            if case .reconnecting(let attempt) = ssh.connectionState {
                Text("Reconnecting (\(attempt)/3)...")
                    .padding(8)
                    .background(.orange.opacity(0.9), in: Capsule())
                    .padding(.top, 40)
            }
        }
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !shellStarted else { return }
            shellStarted = true
            ssh.shellError = nil

            // Load cached content for instant display
            compactLines = SessionCache.load(key: cacheKey)

            do {
                try await ssh.ensureConnected()
            } catch {
                ssh.shellError = "Connect failed: \(error.localizedDescription)"
                return
            }

            ssh.openShell(project: projectName, cols: 80, rows: 24) { [self] data in
                DispatchQueue.main.async {
                    if let tv = self.terminalView {
                        tv.feed(byteArray: ArraySlice([UInt8](data)))
                    }
                }
            }
            startCompactPolling()
        }
        .onDisappear {
            pollingTask?.cancel()
            // Save current content to cache
            SessionCache.save(key: cacheKey, lines: compactLines)
            Task { try? await pollClient?.close() }
            pollClient = nil
            ssh.closeShell()
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Send to Claude...", text: $inputText)
                .font(.system(.body))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)
                .foregroundColor(.white)
                .focused($isInputFocused)
                .onSubmit { sendInput() }

            // ESC — Ctrl+C to interrupt
            Button {
                Task { try? await ssh.sendBytes([0x03]) }
            } label: {
                Text("ESC")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundColor(.red.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(6)
            }

            // Keyboard toggle
            Button {
                isInputFocused.toggle()
            } label: {
                Image(systemName: isInputFocused ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.title3)
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.12))
    }

    private func sendInput() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task { try? await ssh.send(text + "\r") }
        inputText = ""
        isInputFocused = false
    }

    // MARK: - Compact Line View

    @ViewBuilder
    private func compactLineView(_ line: FilteredLine) -> some View {
        switch line.type {
        case .humanInput:
            Text(line.text)
                .font(.system(.body, design: .rounded))
                .foregroundColor(Color(red: 0.55, green: 0.75, blue: 1.0))
        case .toolCall:
            HStack(spacing: 4) {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Color.gray)
            }
        case .toolError:
            HStack(spacing: 4) {
                Circle().fill(Color.red.opacity(0.8)).frame(width: 6, height: 6)
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Color.gray)
            }
        case .info:
            Text(line.text)
                .font(.system(.caption))
                .foregroundColor(Color.gray.opacity(0.6))
        case .aiText:
            let indent = line.text.prefix(while: { $0 == " " }).count
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let isList = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
                || trimmed.range(of: "^\\d+\\.", options: .regularExpression) != nil

            if isList {
                HStack(alignment: .top, spacing: 4) {
                    let parts = trimmed.split(separator: " ", maxSplits: 1)
                    let bullet = String(parts.first ?? "-")
                    let content = parts.count > 1 ? String(parts[1]) : ""
                    Text(bullet)
                        .foregroundColor(.gray)
                    Text(content)
                        .foregroundColor(.white)
                }
                .font(.system(.body))
                .padding(.leading, CGFloat(max(indent / 2, 0) * 12))
            } else {
                Text(trimmed)
                    .font(.system(.body))
                    .foregroundColor(.white)
                    .padding(.leading, CGFloat(max(indent / 2, 0) * 12))
            }
        }
    }

    // MARK: - Compact Polling

    private func startCompactPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await refreshCompactView()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @State private var pollClient: SSHService?

    private func refreshCompactView() async {
        do {
            if pollClient == nil {
                let p = SSHService()
                try await p.connect()
                pollClient = p
            }
            guard let pc = pollClient else { return }
            // Capture full scrollback history
            let raw = try await pc.execute("tmux capture-pane -t \(projectName) -p -S - 2>/dev/null || echo '[no session]'")
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            claudeStatus = filter.extractStatus(from: lines)

            // Truncate at input prompt — everything below is UI chrome
            var contentLines = lines
            if let promptIdx = lines.lastIndex(where: { $0.contains("❯") || $0.contains("\u{276F}") }) {
                contentLines = Array(lines[..<promptIdx])
            }

            filter.reset()
            var filtered: [FilteredLine] = []
            for line in contentLines {
                if let processed = filter.processLine(line) {
                    filtered.append(processed)
                }
            }
            compactLines = mergeConsecutiveText(filtered)
        } catch {
            pollClient = nil
        }
    }

    /// Check if a line is a structural element (list item, heading, etc.) that shouldn't be merged
    private func isStructural(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") { return true }
        if t.range(of: "^\\d+\\.", options: .regularExpression) != nil { return true }  // numbered list
        if t.hasPrefix("#") { return true }  // heading
        if t.hasPrefix("**") && t.hasSuffix("**") { return true }  // bold line = subheading
        return false
    }

    /// Get leading whitespace count for indentation detection
    private func indentLevel(_ text: String) -> Int {
        text.prefix(while: { $0 == " " }).count
    }

    private func mergeConsecutiveText(_ lines: [FilteredLine]) -> [FilteredLine] {
        var result: [FilteredLine] = []
        var buffer = ""
        var bufferType: LineType? = nil

        for line in lines {
            let mergeable = (line.type == .aiText || line.type == .humanInput)
            let structural = isStructural(line.text)

            if mergeable && line.type == bufferType && !structural && indentLevel(line.text) == 0 {
                // Plain continuation paragraph text — merge
                buffer += " " + line.text
            } else {
                // Flush previous buffer
                if !buffer.isEmpty, let type = bufferType {
                    result.append(FilteredLine(text: buffer, type: type))
                }
                if mergeable {
                    buffer = line.text
                    bufferType = line.type
                    // If structural, flush immediately (don't merge with next)
                    if structural {
                        result.append(FilteredLine(text: buffer, type: bufferType!))
                        buffer = ""
                        bufferType = nil
                    }
                } else {
                    buffer = ""
                    bufferType = nil
                    result.append(line)
                }
            }
        }
        if !buffer.isEmpty, let type = bufferType {
            result.append(FilteredLine(text: buffer, type: type))
        }
        return result
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes > 1_000_000 { return String(format: "%.1fMB", Double(bytes) / 1_000_000) }
        if bytes > 1_000 { return String(format: "%.1fKB", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }
}
