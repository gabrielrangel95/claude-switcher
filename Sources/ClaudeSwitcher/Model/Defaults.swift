import Foundation

enum Defaults {
    /// Fixed suite so the app and the CLI (even via a symlink) share settings and account list.
    static let shared = UserDefaults(suiteName: "app.bestbarbers.claude-switcher.shared") ?? .standard
}
