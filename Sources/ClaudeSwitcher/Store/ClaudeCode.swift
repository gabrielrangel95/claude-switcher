import Foundation

typealias JSON = [String: Any]

/// Reads and writes the two places where Claude Code keeps the logged-in account:
/// - Keychain item "Claude Code-credentials" → `claudeAiOauth` (tokens). Other keys such as
///   `mcpOAuth` are preserved untouched.
/// - `~/.claude.json` → `oauthAccount` (identity shown by Claude Code). Other keys are preserved.
enum ClaudeCode {
    static let credentialsService = "Claude Code-credentials"
    static var credentialsAccount: String { NSUserName() }
    static var configURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }
    static var backupURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json.switcher-bak") }

    // MARK: Credentials (Keychain)

    static func readLiveOAuth() throws -> JSON? {
        guard let data = try Keychain.read(service: credentialsService, account: credentialsAccount) else { return nil }
        let root = try JSONSerialization.jsonObject(with: data) as? JSON
        return root?["claudeAiOauth"] as? JSON
    }

    /// Replaces only `claudeAiOauth`, keeping every other key in the item.
    static func writeLiveOAuth(_ oauth: JSON) throws {
        var root: JSON = [:]
        if let data = try Keychain.read(service: credentialsService, account: credentialsAccount) {
            // Refuse to overwrite an item we can't parse rather than dropping its other keys.
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? JSON else {
                throw CocoaError(.fileReadCorruptFile)
            }
            root = parsed
        }
        root["claudeAiOauth"] = oauth
        let data = try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
        try Keychain.write(service: credentialsService, account: credentialsAccount, data: data)
    }

    // MARK: Identity (~/.claude.json)

    static func readOAuthAccount() -> JSON? {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? JSON else { return nil }
        return root["oauthAccount"] as? JSON
    }

    /// Replaces only `oauthAccount`. Writes a backup of the previous file first.
    static func writeOAuthAccount(_ account: JSON) throws {
        let data = try Data(contentsOf: configURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? JSON else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try data.write(to: backupURL, options: .atomic)
        root["oauthAccount"] = account
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: configURL, options: .atomic)
    }

    static func restoreBackup() throws {
        let data = try Data(contentsOf: backupURL)
        _ = try JSONSerialization.jsonObject(with: data) // sanity check
        try data.write(to: configURL, options: .atomic)
    }

    static var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }
}

extension JSON {
    /// Milliseconds since epoch, as Claude Code stores `expiresAt`.
    var expiresAt: Date? {
        (self["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    var accessToken: String? { self["accessToken"] as? String }
    var refreshToken: String? { self["refreshToken"] as? String }

    func expires(within interval: TimeInterval) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < interval
    }
}
