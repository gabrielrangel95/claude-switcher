import Foundation

/// Secrets for each saved account, stored in this app's own Keychain items
/// (service "ClaudeSwitcher", one item per account id).
struct VaultRecord {
    var oauth: JSON          // same shape as Claude Code's `claudeAiOauth`
    var oauthAccount: JSON   // same shape as `~/.claude.json` → `oauthAccount`
}

enum AccountVault {
    static let service = "ClaudeSwitcher"

    static func load(_ id: String) -> VaultRecord? {
        guard let data = try? Keychain.read(service: service, account: id),
              let root = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let oauth = root["oauth"] as? JSON,
              let account = root["oauthAccount"] as? JSON else { return nil }
        return VaultRecord(oauth: oauth, oauthAccount: account)
    }

    static func save(_ record: VaultRecord, id: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["oauth": record.oauth, "oauthAccount": record.oauthAccount],
            options: [.withoutEscapingSlashes]
        )
        try Keychain.write(service: service, account: id, data: data)
    }

    static func delete(_ id: String) {
        Keychain.delete(service: service, account: id)
    }
}
