import SwiftUI
import UserNotifications

@main
struct iostmuxApp: App {
    init() {
        BackgroundMonitor.register()
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
