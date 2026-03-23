import SwiftUI
import SwiftTerm
import PhotosUI

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
    @State private var cachedUsage: UsageQuota?
    @State private var usageLoaded = false
    @State private var inputText = ""
    @State private var showGTDTracker = false
    @State private var gtdProject: GTDProject?
    @State private var usageQuota: UsageQuota?
    @State private var evolveReport: EvolveReport?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var uploadStatus: String?
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
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(compactLines) { line in
                                    compactLineView(line).id(line.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 16)
                        }
                        .background(Color.black)
                        .onAppear {
                            if let last = compactLines.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
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
                    if s.contextUsage > 0 {
                        Text("·")
                            .foregroundColor(.gray)
                        Text("\(s.contextUsage)%")
                            .foregroundColor(s.contextUsage > 80 ? .orange : .white.opacity(0.5))
                    }
                    if let usage = cachedUsage {
                        Text("·")
                            .foregroundColor(.gray)
                        Text("5h:\(Int(usage.fiveHourUtil))%")
                            .foregroundColor(usage.fiveHourUtil > 80 ? .orange : .white.opacity(0.5))
                    }
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
        // Upload status banner
        .overlay(alignment: .bottom) {
            if let status = uploadStatus {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.9), in: Capsule())
                    .padding(.bottom, 60)
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await uploadPhoto(item) }
            selectedPhoto = nil
        }
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showGTDTracker) {
            if let gtdProject {
                GTDTrackerView(
                    project: gtdProject,
                    usage: usageQuota,
                    evolve: evolveReport,
                    sshClient: pollClient,
                    projectName: projectName
                )
                .presentationDetents([.medium, .large])
            }
        }
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

            // Photo upload
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundColor(.green)
            }

            // GTD Tracker
            Button {
                Task { await loadGTDTracker() }
            } label: {
                Image(systemName: "list.bullet.clipboard")
                    .font(.title3)
                    .foregroundColor(.cyan)
            }

            // Arrow keys + Enter + Esc
            HStack(spacing: 2) {
                // Up arrow
                Button { Task { try? await ssh.sendBytes([0x1B, 0x5B, 0x41]) } } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.bold))
                        .frame(width: 28, height: 26)
                }
                // Down arrow
                Button { Task { try? await ssh.sendBytes([0x1B, 0x5B, 0x42]) } } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .frame(width: 28, height: 26)
                }
                // Enter
                Button { Task { try? await ssh.sendBytes([0x0D]) } } label: {
                    Image(systemName: "return")
                        .font(.caption2.weight(.bold))
                        .frame(width: 28, height: 26)
                }
                // Esc (real escape 0x1B)
                Button { Task { try? await ssh.sendBytes([0x1B]) } } label: {
                    Text("⎋")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 26)
                }
                // Ctrl+C
                Button { Task { try? await ssh.sendBytes([0x03]) } } label: {
                    Text("^C")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .frame(width: 28, height: 26)
                }
            }
            .foregroundColor(.orange)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(6)

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
        // Allow empty input — sends Enter for menu confirmation
        Task { try? await ssh.send(text + "\r") }
        inputText = ""
        isInputFocused = false
    }

    // MARK: - Compact Line View

    private static let monoFont = Font.system(.subheadline, design: .monospaced)
    private static let monoSmall = Font.system(.caption, design: .monospaced)

    @ViewBuilder
    private func compactLineView(_ line: FilteredLine) -> some View {
        switch line.type {
        case .humanInput:
            Text(line.text)
                .font(Self.monoFont.weight(.medium))
                .foregroundColor(Color(red: 0.55, green: 0.75, blue: 1.0))
                .padding(.vertical, 2)
                .textSelection(.enabled)
        case .toolCall:
            HStack(spacing: 4) {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                Text(line.text)
                    .font(Self.monoSmall)
                    .foregroundColor(Color.gray)
            }
        case .toolError:
            HStack(spacing: 4) {
                Circle().fill(Color.red.opacity(0.8)).frame(width: 6, height: 6)
                Text(line.text)
                    .font(Self.monoSmall)
                    .foregroundColor(Color.gray)
            }
        case .info:
            Text(line.text)
                .font(Self.monoSmall)
                .foregroundColor(Color.gray.opacity(0.6))
        case .aiText:
            let indent = line.text.prefix(while: { $0 == " " }).count
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let isList = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
                || trimmed.range(of: "^\\d+\\.", options: .regularExpression) != nil
            let isCode = looksLikeCommand(trimmed)

            if isCode {
                linkifiedText(trimmed)
                    .font(Self.monoSmall)
                    .foregroundColor(Color(white: 0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.15))
                    .cornerRadius(6)
                    .textSelection(.enabled)
            } else if isList {
                HStack(alignment: .top, spacing: 6) {
                    let parts = trimmed.split(separator: " ", maxSplits: 1)
                    let bullet = String(parts.first ?? "-")
                    let content = parts.count > 1 ? String(parts[1]) : ""
                    Text(bullet)
                        .foregroundColor(.gray)
                    linkifiedText(content)
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                }
                .font(Self.monoFont)
                .padding(.leading, CGFloat(max(indent / 2, 1) * 16))
                .padding(.vertical, 1)
            } else {
                linkifiedText(trimmed)
                    .font(Self.monoFont)
                    .foregroundColor(.white)
                    .padding(.leading, CGFloat(max(indent / 2, 0) * 16))
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Linkified Text

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s,，。）)）\]】\"']+"#,
        options: []
    )

    /// Build a Text view with tappable links for any URLs found in the string
    private func linkifiedText(_ string: String) -> Text {
        let nsString = string as NSString
        let matches = Self.urlPattern.matches(in: string, range: NSRange(location: 0, length: nsString.length))

        guard !matches.isEmpty else {
            return Text(string)
        }

        var result = Text("")
        var lastEnd = string.startIndex

        for match in matches {
            guard let range = Range(match.range, in: string) else { continue }

            // Text before the URL
            if lastEnd < range.lowerBound {
                result = result + Text(string[lastEnd..<range.lowerBound])
            }

            // The URL itself — styled as a link
            let urlString = String(string[range])
            if let url = URL(string: urlString) {
                var linkText = AttributedString(urlString)
                linkText.link = url
                linkText.foregroundColor = .cyan
                linkText.underlineStyle = .single
                result = result + Text(linkText)
            } else {
                result = result + Text(urlString)
            }

            lastEnd = range.upperBound
        }

        // Remaining text after last URL
        if lastEnd < string.endIndex {
            result = result + Text(string[lastEnd...])
        }

        return result
    }

    /// Detect lines that look like shell commands or code
    private func looksLikeCommand(_ text: String) -> Bool {
        // Skip if contains CJK characters — it's mixed prose, not a pure command
        if text.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
            return false
        }
        // Lines starting with common command prefixes
        let cmdPrefixes = ["rm ", "scp ", "ssh ", "cd ", "ls ", "cat ", "echo ",
                           "git ", "python", "pip ", "npm ", "brew ", "curl ",
                           "xcrun ", "xcodebuild", "mkdir ", "cp ", "mv ",
                           "docker ", "make ", "cargo ", "go ", "swift "]
        let lower = text.lowercased()
        for prefix in cmdPrefixes {
            if lower.hasPrefix(prefix) { return true }
        }
        // Lines starting with $ or # (shell prompt)
        if text.hasPrefix("$ ") || text.hasPrefix("# ") { return true }
        return false
    }

    // MARK: - Photo Upload

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        uploadStatus = "Loading..."
        do {
            guard let imageData = try await item.loadTransferable(type: Data.self) else {
                uploadStatus = "Failed to load image"
                dismissUploadStatus()
                return
            }

            // Compress to JPEG
            guard let uiImage = UIImage(data: imageData),
                  let jpeg = uiImage.jpegData(compressionQuality: 0.8) else {
                uploadStatus = "Failed to compress"
                dismissUploadStatus()
                return
            }

            let filename = "img_\(Int(Date().timeIntervalSince1970)).jpg"
            let remotePath = "/tmp/iostmux_uploads/\(filename)"

            uploadStatus = "Uploading \(formatBytes(jpeg.count))..."

            // Use a separate SSH connection for upload
            let uploader = SSHService()
            try await uploader.connect()
            try await uploader.uploadFile(data: jpeg, remotePath: remotePath)
            try await uploader.close()

            uploadStatus = "Uploaded!"

            // Send path to tmux session
            try await ssh.send(remotePath + "\r")

            dismissUploadStatus()
        } catch {
            uploadStatus = "Upload failed"
            dismissUploadStatus()
        }
    }

    private func dismissUploadStatus() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            uploadStatus = nil
        }
    }

    // MARK: - GTD Tracker

    private func loadGTDTracker() async {
        do {
            if pollClient == nil {
                let p = SSHService()
                try await p.connect()
                pollClient = p
            }
            guard let pc = pollClient else { return }

            // Fetch PROJECT.md and usage
            let content = try await pc.execute("cat ~/Projects/\(projectName)/PROJECT.md 2>/dev/null || echo ''")
            guard !content.isEmpty else { return }
            gtdProject = GTDParser.parse(content)

            let usageJson = try await pc.execute("cat ~/.claude/.cache/usage_default__api_oauth_usage.json 2>/dev/null || echo ''")
            usageQuota = UsageParser.parse(usageJson)

            // Fetch latest evolve report
            let reportPath = try await pc.execute("ls -t ~/Projects/evolve_engine/code/output/*/projects/\(projectName).json 2>/dev/null | head -1")
            let reportPathClean = reportPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reportPathClean.isEmpty && !reportPathClean.contains("No such file") {
                let reportJson = try await pc.execute("cat '\(reportPathClean)' 2>/dev/null || echo ''")
                if var report = EvolveParser.parse(reportJson) {
                    // Extract date from path: .../output/YYYY-MM-DD/projects/...
                    let parts = reportPathClean.components(separatedBy: "/")
                    if let dateIdx = parts.firstIndex(of: "output"), dateIdx + 1 < parts.count {
                        report.reportDate = parts[dateIdx + 1]
                    }
                    // Load feedback
                    if !report.reportDate.isEmpty {
                        let feedback = try await pc.execute("cat ~/Projects/evolve_engine/code/feedback/\(report.reportDate).jsonl 2>/dev/null || echo ''")
                        EvolveParser.applyFeedback(feedback, to: &report, projectId: projectName)
                    }
                    evolveReport = report
                }
            }

            showGTDTracker = true
        } catch {
            // silently fail
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

            // Capture status bar with wider window to avoid truncation
            let wideStatus = try await pc.execute("tmux resize-window -t \(projectName) -x 200 2>/dev/null; tmux capture-pane -t \(projectName) -p -S -3 2>/dev/null; tmux resize-window -t \(projectName) -x 80 2>/dev/null")
            let statusLines = wideStatus.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            claudeStatus = filter.extractStatus(from: statusLines)

            // Load usage from cache file (once)
            if !usageLoaded {
                let usageJson = try await pc.execute("cat ~/.claude/.cache/usage_default__api_oauth_usage.json 2>/dev/null || echo ''")
                cachedUsage = UsageParser.parse(usageJson)
                usageLoaded = true
            }

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
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)

            // Detect URL/word continuation: previous line ended mid-word/URL, this line continues it
            let isContinuation = mergeable && !result.isEmpty && !trimmed.isEmpty
                && !structural && trimmed.first?.isUppercase == false
                && (result.last?.text.hasSuffix("-") == true
                    || result.last?.text.range(of: "https?://\\S+$", options: .regularExpression) != nil)

            if isContinuation, let last = result.popLast() {
                // Append directly without space (URL or hyphenated word continuation)
                let joinChar = last.text.hasSuffix("-") ? "" : ""
                result.append(FilteredLine(text: last.text + joinChar + trimmed, type: last.type))
            } else if mergeable && line.type == bufferType && !structural && indentLevel(line.text) == 0 {
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
