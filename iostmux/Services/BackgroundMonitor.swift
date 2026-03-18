import Foundation
import BackgroundTasks
import UserNotifications
import Citadel
import Crypto
import NIO

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
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleBackgroundTask(_ task: BGAppRefreshTask) {
        scheduleNextCheck()

        let checkTask = Task {
            do {
                let sessions = try await executeQuickCommand(
                    "tmux list-sessions -F '#{session_name}' 2>/dev/null"
                )
                for session in sessions.split(separator: "\n") {
                    let lastLines = try await executeQuickCommand(
                        "tmux capture-pane -t \(session) -p 2>/dev/null | tail -3"
                    )
                    if lastLines.contains("\u{276F}") { // ❯
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
        guard let keyData = KeychainHelper.loadPrivateKey() else {
            throw SSHError.noKey
        }
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyData)
        let client = try await SSHClient.connect(
            host: Config.sshHost,
            port: Int(Config.sshPort),
            authenticationMethod: .ed25519(username: Config.sshUser, privateKey: privateKey),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        let output = try await client.executeCommand(command, inShell: true)
        try await client.close()
        return String(buffer: output)
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
