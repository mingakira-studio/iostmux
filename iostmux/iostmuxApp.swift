import SwiftUI
import UserNotifications

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
