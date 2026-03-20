import Foundation

enum Config {
    static let appVersion = "v20"  // Increment on each deploy to verify
    static let sshHost = "100.92.191.56" // Mac Studio Tailscale IP
    static let sshPort: UInt16 = 22
    static let sshUser = "ming"
    static let projectsPath = "~/Projects"
}
