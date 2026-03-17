# iostmux Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an iOS app that SSH-connects to Mac Studio, lists projects, attaches to Claude Code tmux sessions with filtered output, voice input, and background completion notifications.

**Architecture:** SwiftUI app wrapping SwiftTerm (UIKit terminal emulator) via UIViewRepresentable. SSH via libssh2 (SwiftSH wrapper) for interactive shell support. Output filter state machine sits between SSH channel and SwiftTerm feed. Background App Refresh polls for Claude idle prompt.

**Tech Stack:** SwiftUI, SwiftTerm (SPM), SwiftSH (SPM, libssh2 wrapper), Speech framework, iOS 17+

**Spec deviation:** Citadel replaced with SwiftSH — research shows Citadel lacks interactive shell/PTY channel API needed for tmux attach. SwiftSH wraps libssh2 with proven `Shell.write()` for bidirectional interactive sessions.

**Risk note:** SwiftSH (`Frugghi/SwiftSH`) has not been updated recently. If it doesn't compile against current Xcode/Swift, consider forking or switching to direct libssh2 bindings. The chained API patterns in this plan (`.connect().authenticate().open()`) should be verified against SwiftSH source early in Task 2.

---

## File Structure

```
iostmux/
├── iostmux.xcodeproj
├── iostmux/
│   ├── iostmuxApp.swift                    — App entry point, background task registration
│   ├── Config.swift                        — Hardcoded SSH config (IP, user, port)
│   ├── Models/
│   │   └── Project.swift                   — Project model (name, hasActiveSession)
│   ├── Services/
│   │   ├── SSHService.swift                — SSH connection management (SwiftSH wrapper)
│   │   ├── OutputFilter.swift              — State machine for compact mode filtering
│   │   └── BackgroundMonitor.swift         — Background App Refresh + notification logic
│   ├── Views/
│   │   ├── ProjectListView.swift           — Project list with session status dots
│   │   ├── SessionView.swift               — Terminal session container + controls overlay
│   │   ├── TerminalViewWrapper.swift        — UIViewRepresentable wrapping SwiftTerm
│   │   ├── GestureKeyboardView.swift       — Swipe-up keyboard with special keys
│   │   └── VoiceInputButton.swift          — Floating mic button with Speech framework
│   └── Info.plist                          — Background modes, microphone usage
└── Package dependencies: SwiftTerm, SwiftSH
```

---

## Task 1: Xcode Project + Dependencies

**Files:**
- Create: `iostmux.xcodeproj` (via Xcode)
- Create: `iostmux/iostmuxApp.swift`
- Create: `iostmux/Config.swift`

- [ ] **Step 1: Create Xcode project**

Create new Xcode project: iOS App, SwiftUI, name `iostmux`, bundle ID `com.ming.iostmux`, deployment target iOS 17.0, portrait only.

- [ ] **Step 2: Add SwiftTerm package dependency**

File → Add Package Dependencies → `https://github.com/migueldeicaza/SwiftTerm` → branch `main`

- [ ] **Step 3: Add SwiftSH package dependency**

File → Add Package Dependencies → `https://github.com/Frugghi/SwiftSH` → branch `master`

- [ ] **Step 4: Create Config.swift**

```swift
// iostmux/Config.swift
import Foundation

enum Config {
    static let sshHost = "100.x.x.x" // Tailscale IP - replace with actual
    static let sshPort: UInt16 = 22
    static let sshUser = "ming"
    static let projectsPath = "~/Projects"
}
```

- [ ] **Step 5: Create minimal app entry point**

```swift
// iostmux/iostmuxApp.swift
import SwiftUI

@main
struct iostmuxApp: App {
    var body: some Scene {
        WindowGroup {
            ProjectListView()
        }
    }
}
```

- [ ] **Step 6: Build to verify dependencies resolve**

Product → Build (⌘B). Expected: Build succeeds with no errors.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: init Xcode project with SwiftTerm and SwiftSH dependencies"
```

---

## Task 2: SSH Service

**Files:**
- Create: `iostmux/Services/SSHService.swift`
- Create: `iostmux/Models/Project.swift`

- [ ] **Step 1: Create Project model**

```swift
// iostmux/Models/Project.swift
import Foundation

struct Project: Identifiable, Comparable {
    let id = UUID()
    let name: String
    var hasActiveSession: Bool

    static func < (lhs: Project, rhs: Project) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
```

- [ ] **Step 2: Create SSHService**

```swift
// iostmux/Services/SSHService.swift
import Foundation
import SwiftSH

class SSHService: ObservableObject {
    private var command: SSHCommand?
    private var shell: SSHShell?

    /// Execute a single command, return output
    func execute(_ command: String) async throws -> String {
        let ssh = SSHCommand(host: Config.sshHost,
                             port: Config.sshPort)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ssh.connect()
                .authenticate(.byPassword(username: Config.sshUser, password: ""))
                .completion { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
        }
        let output: String = try await withCheckedThrowingContinuation { cont in
            ssh.execute(command) { (cmd, output, error) in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: output ?? "") }
            }
        }
        ssh.disconnect()
        return output
    }

    /// Fetch project list with tmux session status
    func fetchProjects() async throws -> [Project] {
        let dirs = try await execute("ls -1 \(Config.projectsPath)")
        let sessions = try await execute("tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
        let sessionSet = Set(sessions.split(separator: "\n").map(String.init))
        return dirs.split(separator: "\n")
            .map { name in
                let n = String(name)
                return Project(name: n, hasActiveSession: sessionSet.contains(n))
            }
            .sorted()
    }

    /// Open interactive shell for tmux session
    func openShell(
        project: String,
        onData: @escaping (Data) -> Void
    ) async throws -> SSHShell {
        let sh = SSHShell(host: Config.sshHost, port: Config.sshPort)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sh.connect()
                .authenticate(.byPassword(username: Config.sshUser, password: ""))
                .open { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
        }
        sh.setReadHandler(onData)
        let cmd = "tmux attach-session -t \(project) 2>/dev/null || (cd ~/Projects/\(project) && ccc)"
        sh.write(cmd + "\n")
        self.shell = sh
        return sh
    }

    /// Send text to active shell
    func send(_ text: String) {
        shell?.write(text)
    }

    /// Send raw bytes (for escape sequences)
    func sendBytes(_ bytes: [UInt8]) {
        shell?.write(Data(bytes))
    }

    /// Detach and close
    func closeShell() {
        // Send tmux detach key: Ctrl+B, d
        shell?.write(Data([0x02])) // Ctrl+B
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.shell?.write("d")
            self?.shell?.disconnect()
            self?.shell = nil
        }
    }
}
```

> **Note:** Authentication method will need adjustment. For key-based auth, SwiftSH supports `.byPublicKeyFromFile(username:password:publicKeyPath:privateKeyPath:)`. The password-based auth above is a placeholder — Task 6 implements proper key auth. For now this gets the architecture working.

- [ ] **Step 3: Build to verify compilation**

Expected: Builds with no errors. Cannot test SSH yet (needs device or adjusted auth).

- [ ] **Step 4: Commit**

```bash
git add iostmux/Models/Project.swift iostmux/Services/SSHService.swift
git commit -m "feat: add SSHService with project listing and shell management"
```

---

## Task 3: Project List View

**Files:**
- Create: `iostmux/Views/ProjectListView.swift`
- Modify: `iostmux/iostmuxApp.swift`

- [ ] **Step 1: Create ProjectListView**

```swift
// iostmux/Views/ProjectListView.swift
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
            projects = try await ssh.fetchProjects()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
```

- [ ] **Step 2: Build and preview**

Build (⌘B). SwiftUI preview won't work (needs SSH), but verify no compilation errors.

- [ ] **Step 3: Commit**

```bash
git add iostmux/Views/ProjectListView.swift
git commit -m "feat: add ProjectListView with session status indicators"
```

---

## Task 4: Terminal View (SwiftTerm Wrapper + Session)

**Files:**
- Create: `iostmux/Views/TerminalViewWrapper.swift`
- Create: `iostmux/Views/SessionView.swift`

- [ ] **Step 1: Create SwiftTerm UIViewRepresentable wrapper**

```swift
// iostmux/Views/TerminalViewWrapper.swift
import SwiftUI
import SwiftTerm

struct TerminalViewWrapper: UIViewRepresentable {
    let onTerminalCreated: (TerminalView) -> Void

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.configureNativeColors()
        // Use a reasonable default font size for iPhone
        let fontSize: CGFloat = 12
        tv.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.nativeForegroundColor = .white
        tv.nativeBackgroundColor = .black
        tv.delegate = context.coordinator
        onTerminalCreated(tv)
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        var onUserInput: (([UInt8]) -> Void)?

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onUserInput?(Array(data))
        }

        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        var onSizeChanged: ((Int, Int) -> Void)?

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onSizeChanged?(newCols, newRows)
        }
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }
}
```

- [ ] **Step 2: Create SessionView**

```swift
// iostmux/Views/SessionView.swift
import SwiftUI
import SwiftTerm

struct SessionView: View {
    let projectName: String
    let ssh: SSHService

    @State private var terminalView: TerminalView?
    @State private var isCompactMode = true
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
                TerminalViewWrapper { tv in
                    self.terminalView = tv
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
        .onDisappear { ssh.closeShell() }
    }

    private func connect() async {
        isConnecting = true
        connectionError = nil
        do {
            let _ = try await ssh.openShell(project: projectName) { data in
                DispatchQueue.main.async {
                    terminalView?.feed(byteArray: [UInt8](data))
                }
            }
            // Wire user input from terminal back to SSH
            if let wrapper = terminalView {
                // Access coordinator via the view hierarchy — handled in TerminalViewWrapper
            }
            isConnecting = false
        } catch {
            connectionError = error.localizedDescription
            isConnecting = false
        }
    }
}
```

> **Note:** The user input wiring (terminal → SSH) needs the coordinator's `onUserInput` connected to `ssh.sendBytes()`. This will be refined when we wire everything together in Task 5.

- [ ] **Step 3: Build to verify**

Expected: Builds. Terminal won't render data yet until SSH is connected on device.

- [ ] **Step 4: Commit**

```bash
git add iostmux/Views/TerminalViewWrapper.swift iostmux/Views/SessionView.swift
git commit -m "feat: add SwiftTerm wrapper and SessionView for tmux attachment"
```

---

## Task 5: Output Filter State Machine

**Files:**
- Create: `iostmux/Services/OutputFilter.swift`
- Modify: `iostmux/Views/SessionView.swift` (integrate filter)

- [ ] **Step 1: Create OutputFilter**

```swift
// iostmux/Services/OutputFilter.swift
import Foundation

class OutputFilter {
    enum State {
        case show
        case toolBlock
    }

    private(set) var state: State = .show
    private let toolKeywords = ["Read", "Write", "Edit", "Bash", "Grep", "Glob",
                                 "Agent", "Skill", "WebSearch", "WebFetch",
                                 "LSP", "TodoWrite", "NotebookEdit"]
    private let alwaysHidePatterns = [
        "Allow .+\\? \\[Y/n\\]",
        "Ctrl\\+C to interrupt",
    ]
    private let alwaysShowPatterns = [
        "❯",  // User prompt
        "^>",  // User input prefix
        "^Error",
        "^Warning",
    ]

    /// Strip ANSI escape codes from a string
    func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\x1b\\[[0-9;]*[A-Za-z]|\\x1b\\].*?\\x07|\\x1b\\].*?\\x1b\\\\",
            with: "",
            options: .regularExpression
        )
    }

    /// Process a line, return true if it should be shown in compact mode
    func shouldShow(line: String) -> Bool {
        let clean = stripANSI(line).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return state == .show }

        // Always-hide patterns
        for pattern in alwaysHidePatterns {
            if clean.range(of: pattern, options: .regularExpression) != nil {
                return false
            }
        }

        // Always-show patterns
        for pattern in alwaysShowPatterns {
            if clean.range(of: pattern, options: .regularExpression) != nil {
                state = .show
                return true
            }
        }

        // State transitions
        if clean.contains("⏺") {
            let isToolCall = toolKeywords.contains { clean.contains("⏺ \($0)") || clean.contains("⏺  \($0)") }
            if isToolCall {
                state = .toolBlock
                return false
            } else {
                // Claude response marker
                state = .show
                return true
            }
        }

        return state == .show
    }

    /// Process a chunk of terminal output, return filtered text for compact view
    func filterChunk(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { shouldShow(line: String($0)) }
            .joined(separator: "\n")
    }

    func reset() {
        state = .show
    }
}
```

- [ ] **Step 2: Integrate filter into SessionView**

Update `SessionView` to maintain an `OutputFilter` and a `compactText` buffer. In compact mode, show a `ScrollView` with filtered text instead of the raw `TerminalViewWrapper`. In raw mode, show the `TerminalViewWrapper`.

Add to SessionView:
```swift
@State private var filter = OutputFilter()
@State private var compactLines: [String] = []
```

Update the SSH data handler in `connect()`:
```swift
let _ = try await ssh.openShell(project: projectName) { data in
    DispatchQueue.main.async {
        // Always feed raw terminal
        terminalView?.feed(byteArray: [UInt8](data))
        // Also filter for compact view
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            if filter.shouldShow(line: String(line)) {
                compactLines.append(String(line))
                // Keep buffer bounded
                if compactLines.count > 500 {
                    compactLines.removeFirst(100)
                }
            }
        }
    }
}
```

Update the body to use ZStack with both views always present (dual-buffer per spec). Toggle visibility with opacity to avoid destroying SwiftTerm state:

```swift
ZStack {
    // Raw terminal — always alive, hidden in compact mode
    TerminalViewWrapper(
        onTerminalCreated: { tv in self.terminalView = tv },
        onUserInput: { bytes in ssh.sendBytes(bytes) }
    )
    .opacity(isCompactMode ? 0 : 1)

    // Compact filtered view
    ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading) {
                ForEach(Array(compactLines.enumerated()), id: \.offset) { idx, line in
                    Text(line)
                        .font(.system(.body, design: .default))
                        .foregroundStyle(.primary)
                        .id(idx)
                }
            }
            .padding()
            .onChange(of: compactLines.count) { _, newCount in
                proxy.scrollTo(newCount - 1, anchor: .bottom)
            }
        }
    }
    .opacity(isCompactMode ? 1 : 0)
}
```

- [ ] **Step 3: Build to verify**

Expected: Compiles. Filter logic will be validated when running on device.

- [ ] **Step 4: Commit**

```bash
git add iostmux/Services/OutputFilter.swift iostmux/Views/SessionView.swift
git commit -m "feat: add output filter state machine with compact/raw mode toggle"
```

---

## Task 6: SSH Key Authentication

**Files:**
- Modify: `iostmux/Services/SSHService.swift` (switch from password to key auth)
- Modify: `iostmux/Views/ProjectListView.swift` (add first-run key setup)

- [ ] **Step 1: Add Keychain helper for SSH key storage**

Add to SSHService or create a small helper:

```swift
import Security

enum KeychainHelper {
    private static let service = "com.ming.iostmux.sshkey"

    static func save(privateKey: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "privatekey",
            kSecValueData as String: privateKey,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "Keychain", code: Int(status))
        }
    }

    static func loadPrivateKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "privatekey",
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static var hasKey: Bool { loadPrivateKey() != nil }
}
```

- [ ] **Step 2: Add key setup view**

```swift
// In ProjectListView, add first-run overlay:
struct KeySetupView: View {
    @State private var keyText = ""
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Paste SSH Private Key") {
                    TextEditor(text: $keyText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200)
                }
                Section {
                    Button("Paste from Clipboard") {
                        keyText = UIPasteboard.general.string ?? ""
                    }
                }
                Section {
                    Button("Save Key") {
                        guard let data = keyText.data(using: .utf8) else { return }
                        try? KeychainHelper.save(privateKey: data)
                        onSave()
                    }
                    .disabled(keyText.isEmpty)
                }
            }
            .navigationTitle("SSH Key Setup")
        }
    }
}
```

- [ ] **Step 3: Update SSHService to use key auth**

Update `execute()` and `openShell()` authentication:
```swift
// Write private key to temp file for SwiftSH
private func writeKeyToTemp() -> String? {
    guard let keyData = KeychainHelper.loadPrivateKey() else { return nil }
    let tempDir = FileManager.default.temporaryDirectory
    let keyPath = tempDir.appendingPathComponent("iostmux_key")
    try? keyData.write(to: keyPath)
    // Set permissions
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
    return keyPath.path
}

// In authenticate calls, replace .byPassword with:
guard let keyPath = writeKeyToTemp() else { throw NSError(domain: "iostmux", code: 1, userInfo: [NSLocalizedDescriptionKey: "No SSH key"]) }
// ...then in the auth chain:
.authenticate(.byPublicKeyFromFile(
    username: Config.sshUser,
    password: "",
    publicKeyPath: nil,
    privateKeyPath: keyPath
))
```

- [ ] **Step 4: Update ProjectListView to gate on key presence**

```swift
@State private var hasKey = KeychainHelper.hasKey

var body: some View {
    if hasKey {
        // existing NavigationStack...
    } else {
        KeySetupView { hasKey = true }
    }
}
```

- [ ] **Step 5: Build and test on device**

Deploy to iPhone. First launch should show key setup. Paste SSH key, save, verify project list loads.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add SSH key auth with Keychain storage and first-run setup"
```

---

## Task 7: Wire User Input (Terminal → SSH)

**Files:**
- Modify: `iostmux/Views/TerminalViewWrapper.swift`
- Modify: `iostmux/Views/SessionView.swift`

- [ ] **Step 1: Pass sendBytes callback through TerminalViewWrapper**

Update `TerminalViewWrapper` to accept `onUserInput` and `onSizeChanged` closures:

```swift
struct TerminalViewWrapper: UIViewRepresentable {
    let onTerminalCreated: (TerminalView) -> Void
    var onUserInput: (([UInt8]) -> Void)?
    var onSizeChanged: ((Int, Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.onUserInput = onUserInput
        c.onSizeChanged = onSizeChanged
        return c
    }

    // ... rest unchanged
}
```

- [ ] **Step 2: Connect in SessionView and wire PTY size**

In SessionView body, update TerminalViewWrapper usage and add PTY size negotiation:

```swift
TerminalViewWrapper(
    onTerminalCreated: { tv in self.terminalView = tv },
    onUserInput: { bytes in ssh.sendBytes(bytes) },
    onSizeChanged: { cols, rows in ssh.sendWindowChange(cols: cols, rows: rows) }
)
```

Add to SSHService:
```swift
/// Notify remote of terminal size change
func sendWindowChange(cols: Int, rows: Int) {
    // SwiftSH shell resize — set terminal dimensions
    shell?.setTerminalSize(width: UInt(cols), height: UInt(rows))
}
```

> **Note:** Verify SwiftSH's actual resize API. If `setTerminalSize` doesn't exist, may need to send SSH window-change request at the libssh2 level.

- [ ] **Step 3: Test on device**

Deploy, navigate to a project, type in raw mode. Keystrokes should appear in tmux session.

- [ ] **Step 4: Commit**

```bash
git add iostmux/Views/TerminalViewWrapper.swift iostmux/Views/SessionView.swift
git commit -m "feat: wire terminal user input to SSH channel"
```

---

## Task 8: Voice Input

**Files:**
- Create: `iostmux/Views/VoiceInputButton.swift`
- Modify: `iostmux/Views/SessionView.swift` (add button overlay)
- Modify: `iostmux/Info.plist` (microphone permission)

- [ ] **Step 1: Add microphone usage description**

In Info.plist or Xcode target → Info → Custom iOS Target Properties:
```
NSMicrophoneUsageDescription: "Voice input for Claude Code sessions"
NSSpeechRecognitionUsageDescription: "Convert speech to text for terminal input"
```

- [ ] **Step 2: Create VoiceInputButton**

```swift
// iostmux/Views/VoiceInputButton.swift
import SwiftUI
import Speech

struct VoiceInputButton: View {
    let onText: (String) -> Void
    @State private var isRecording = false
    @State private var recognizedText = ""
    @State private var audioEngine = AVAudioEngine()
    @State private var recognitionTask: SFSpeechRecognitionTask?

    var body: some View {
        Button {
            if isRecording { stopRecording() }
            else { startRecording() }
        } label: {
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.title2)
                .foregroundStyle(isRecording ? .red : .white)
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func startRecording() {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return }
            AVAudioApplication.requestRecordPermission { granted in
                guard granted else { return }
                DispatchQueue.main.async { beginSession() }
            }
        }
    }

    private func beginSession() {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))
            ?? SFSpeechRecognizer()!
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()
        isRecording = true

        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                recognizedText = result.bestTranscription.formattedString
                if result.isFinal {
                    stopRecording()
                    onText(recognizedText)
                }
            }
            if error != nil { stopRecording() }
        }
    }

    private func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
    }
}
```

- [ ] **Step 3: Add to SessionView**

Overlay the voice button at bottom-right of the session view:

```swift
.overlay(alignment: .bottomTrailing) {
    VoiceInputButton { text in
        ssh.send(text + "\n")
    }
    .padding()
}
```

- [ ] **Step 4: Test on device**

Deploy, open a session, tap mic, speak. Text should be sent to terminal after recognition completes.

- [ ] **Step 5: Commit**

```bash
git add iostmux/Views/VoiceInputButton.swift iostmux/Views/SessionView.swift
git commit -m "feat: add voice input with Speech framework"
```

---

## Task 9: Gesture Keyboard

**Files:**
- Create: `iostmux/Views/GestureKeyboardView.swift`
- Modify: `iostmux/Views/SessionView.swift` (add gesture + overlay)

- [ ] **Step 1: Create GestureKeyboardView**

```swift
// iostmux/Views/GestureKeyboardView.swift
import SwiftUI

struct GestureKeyboardView: View {
    let onKey: (String) -> Void
    let onBytes: ([UInt8]) -> Void
    @State private var inputText = ""

    private let quickActions = ["/commit", "/help", "yes", "no"]

    private let specialKeys: [(String, [UInt8])] = [
        ("⇥", [0x09]),          // Tab
        ("⎋", [0x1b]),          // Esc
        ("^C", [0x03]),         // Ctrl+C
        ("↑", [0x1b, 0x5b, 0x41]),  // Arrow up
        ("↓", [0x1b, 0x5b, 0x42]),  // Arrow down
        ("←", [0x1b, 0x5b, 0x44]),  // Arrow left
        ("→", [0x1b, 0x5b, 0x43]),  // Arrow right
        ("⏎", [0x0d]),         // Enter
    ]

    var body: some View {
        VStack(spacing: 8) {
            // Quick actions row
            HStack(spacing: 8) {
                ForEach(quickActions, id: \.self) { action in
                    Button(action) {
                        onKey(action + "\n")
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }

            // Special keys row
            HStack(spacing: 8) {
                ForEach(specialKeys, id: \.0) { label, bytes in
                    Button(label) {
                        onBytes(bytes)
                    }
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 36, minHeight: 36)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }

            // Text input field for arbitrary typing
            HStack {
                TextField("Type here...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        onKey(inputText + "\n")
                        inputText = ""
                    }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}
```

- [ ] **Step 2: Add swipe gesture to SessionView**

```swift
@State private var showKeyboard = false

// In body, add gesture and overlay:
.gesture(
    DragGesture(minimumDistance: 50)
        .onEnded { value in
            if value.translation.height < -50 {
                withAnimation { showKeyboard = true }
            } else if value.translation.height > 50 {
                withAnimation { showKeyboard = false }
            }
        }
)
.overlay(alignment: .bottom) {
    if showKeyboard {
        GestureKeyboardView(
            onKey: { text in ssh.send(text) },
            onBytes: { bytes in ssh.sendBytes(bytes) }
        )
        .transition(.move(edge: .bottom))
    }
}
```

- [ ] **Step 3: Test on device**

Deploy, swipe up to reveal keyboard, tap special keys, type text. Verify escape sequences arrive correctly in tmux.

- [ ] **Step 4: Commit**

```bash
git add iostmux/Views/GestureKeyboardView.swift iostmux/Views/SessionView.swift
git commit -m "feat: add gesture-activated keyboard with special keys and quick actions"
```

---

## Task 10: Reconnection Handling

**Files:**
- Modify: `iostmux/Services/SSHService.swift`
- Modify: `iostmux/Views/SessionView.swift`

- [ ] **Step 1: Add disconnect detection to SSHService**

Add a `connectionState` published property and reconnection logic:

```swift
enum ConnectionState {
    case connected, disconnected, reconnecting(attempt: Int)
}

@Published var connectionState: ConnectionState = .disconnected

func reconnect(project: String, onData: @escaping (Data) -> Void) async throws {
    for attempt in 1...3 {
        connectionState = .reconnecting(attempt: attempt)
        try await Task.sleep(for: .seconds(2))
        do {
            let _ = try await openShell(project: project, onData: onData)
            connectionState = .connected
            return
        } catch {
            if attempt == 3 { throw error }
        }
    }
}
```

- [ ] **Step 2: Add reconnect banner to SessionView**

Show a banner based on `ssh.connectionState`:

```swift
.overlay(alignment: .top) {
    switch ssh.connectionState {
    case .disconnected:
        HStack {
            Text("Connection lost")
            Button("Reconnect") { Task { try? await ssh.reconnect(project: projectName, onData: dataHandler) } }
        }
        .padding(8)
        .background(.red.opacity(0.9), in: Capsule())
        .padding(.top, 8)
    case .reconnecting(let attempt):
        Text("Reconnecting (\(attempt)/3)...")
            .padding(8)
            .background(.orange.opacity(0.9), in: Capsule())
            .padding(.top, 8)
    case .connected:
        EmptyView()
    }
}
```

- [ ] **Step 3: Build and verify**

Expected: Compiles. Reconnection tested by toggling Tailscale off/on on device.

- [ ] **Step 4: Commit**

```bash
git add iostmux/Services/SSHService.swift iostmux/Views/SessionView.swift
git commit -m "feat: add auto-reconnection with banner UI"
```

---

## Task 11: Background Completion Monitor

**Files:**
- Create: `iostmux/Services/BackgroundMonitor.swift`
- Modify: `iostmux/iostmuxApp.swift` (register background task)
- Modify: `iostmux/Info.plist` (background modes)

- [ ] **Step 1: Enable background modes**

In Xcode target → Signing & Capabilities → + Background Modes:
- Check "Background fetch"
- Check "Background processing"

Add to Info.plist → `BGTaskSchedulerPermittedIdentifiers`:
```xml
<array>
    <string>com.ming.iostmux.sessioncheck</string>
</array>
```

- [ ] **Step 2: Create BackgroundMonitor**

```swift
// iostmux/Services/BackgroundMonitor.swift
import Foundation
import BackgroundTasks
import UserNotifications
import SwiftSH

class BackgroundMonitor {
    static let taskIdentifier = "com.ming.iostmux.sessioncheck"

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            handleBackgroundTask(task as! BGAppRefreshTask)
        }
    }

    static func scheduleNextCheck() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60) // 1 min minimum
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleBackgroundTask(_ task: BGAppRefreshTask) {
        scheduleNextCheck() // Schedule next run

        let checkTask = Task {
            do {
                let ssh = SSHCommand(host: Config.sshHost, port: Config.sshPort)
                // Quick connect, check for idle prompt
                // Run: tmux capture-pane -t <session> -p | tail -5 | grep '❯'
                let output = try await executeQuickCommand(
                    "tmux list-sessions -F '#{session_name}' 2>/dev/null"
                )
                let sessions = output.split(separator: "\n")
                for session in sessions {
                    let lastLines = try await executeQuickCommand(
                        "tmux capture-pane -t \(session) -p 2>/dev/null | tail -3"
                    )
                    if lastLines.contains("❯") {
                        await sendNotification(session: String(session))
                    }
                }
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = { checkTask.cancel() }
    }

    private static func executeQuickCommand(_ command: String) async throws -> String {
        // Ensure key file exists (temp dir may be purged between app launches)
        let keyFile = ensureKeyFile()
        guard let keyFile else { throw NSError(domain: "iostmux", code: 1, userInfo: [NSLocalizedDescriptionKey: "No SSH key in Keychain"]) }

        return try await withCheckedThrowingContinuation { cont in
            let ssh = SSHCommand(host: Config.sshHost, port: Config.sshPort)
            ssh.connect()
                .authenticate(.byPublicKeyFromFile(
                    username: Config.sshUser,
                    password: "",
                    publicKeyPath: nil,
                    privateKeyPath: keyFile
                ))
                .execute(command) { (_, output, error) in
                    ssh.disconnect()
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: output ?? "") }
                }
        }
    }

    /// Write SSH key from Keychain to temp file (needed because SwiftSH reads from file path)
    private static func ensureKeyFile() -> String? {
        guard let keyData = KeychainHelper.loadPrivateKey() else { return nil }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("iostmux_key")
        try? keyData.write(to: path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return path.path
    }

    private static func sendNotification(session: String) async {
        let center = UNUserNotificationCenter.current()
        let _ = try? await center.requestAuthorization(options: [.alert, .sound])

        let content = UNMutableNotificationContent()
        content.title = "Claude Ready"
        content.body = "\(session): Claude is waiting for input"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "claude-idle-\(session)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
```

- [ ] **Step 3: Register in app entry point**

Update `iostmuxApp.swift`:

```swift
@main
struct iostmuxApp: App {
    init() {
        BackgroundMonitor.register()
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didEnterBackgroundNotification
                )) { _ in
                    BackgroundMonitor.scheduleNextCheck()
                }
        }
    }
}
```

- [ ] **Step 4: Build and test**

Deploy to device. Send app to background, wait for Claude to finish a task, verify notification appears.

> **Note:** iOS Background App Refresh timing is controlled by the OS. For testing, use Xcode → Debug → Simulate Background Fetch.

- [ ] **Step 5: Commit**

```bash
git add iostmux/Services/BackgroundMonitor.swift iostmux/iostmuxApp.swift
git commit -m "feat: add background monitor for Claude idle detection with local notifications"
```

---

## Task 12: Final Polish + Device Testing

**Files:**
- Various tweaks across all files

- [ ] **Step 1: Add app icon placeholder**

Add a simple placeholder icon in Assets.xcassets. Can be replaced later.

- [ ] **Step 2: Lock orientation to portrait**

In Xcode target → General → Deployment Info → only check "Portrait".

- [ ] **Step 3: Full device test pass**

Deploy to iPhone. Test the complete flow:
1. First launch → key setup screen → paste key → save
2. Project list loads → green dots on active sessions
3. Tap project with active session → terminal attaches
4. Compact mode shows only Claude text responses
5. Toggle to raw mode → full terminal output
6. Voice input → tap mic → speak → text sent
7. Swipe up → keyboard appears → tap special keys
8. Navigate back → tmux detaches
9. Background → notification when Claude finishes

- [ ] **Step 4: Fix any issues found during testing**

Address compilation errors, layout issues, auth problems.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat: final polish and device testing fixes"
```
