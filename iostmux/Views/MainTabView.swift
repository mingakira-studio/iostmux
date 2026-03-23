import SwiftUI

struct MainTabView: View {
    @StateObject private var ssh = SSHService()
    @State private var hasKey = KeychainHelper.hasKey

    var body: some View {
        if hasKey {
            TabView {
                SessionsTab(ssh: ssh)
                    .tabItem {
                        Label("Sessions", systemImage: "terminal")
                    }

                DashboardTab(ssh: ssh)
                    .tabItem {
                        Label("Dashboard", systemImage: "square.grid.2x2")
                    }
            }
        } else {
            KeySetupView { hasKey = true }
        }
    }
}
