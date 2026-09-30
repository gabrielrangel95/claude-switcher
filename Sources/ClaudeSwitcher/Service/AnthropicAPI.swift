import Foundation

/// The endpoints Claude Code itself calls. They are not publicly documented, so every
/// response is decoded defensively.
enum AnthropicAPI {
    static let apiBase = URL(string: "https://api.anthropic.com")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's public OAuth client id.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    enum Failure: Error, LocalizedError {
        case http(Int)
        case unauthorized
        case malformed

        var errorDescription: String? {
            switch self {
            case .http(let code): return "HTTP \(code)"
            case .unauthorized: return "Login expired — log in to this account again"
            case .malformed: return "Unexpected response"
            }
        }
    }

    struct Profile {
        var accountID: String
        var oauthAccount: JSON   // built in the shape Claude Code stores in ~/.claude.json
        var email: String
        var organizationName: String
    }

    static func profile(accessToken: String) async throws -> Profile {
        let root = try await get("api/oauth/profile", token: accessToken)
        guard let account = root["account"] as? JSON, let org = root["organization"] as? JSON,
              let accountUuid = account["uuid"] as? String, let orgUuid = org["uuid"] as? String else {
            throw Failure.malformed
        }
        var oauthAccount: JSON = [
            "accountUuid": accountUuid,
            "organizationUuid": orgUuid,
        ]
        let mapping: [(JSON, String, String)] = [
            (account, "email", "emailAddress"),
            (account, "display_name", "displayName"),
            (account, "full_name", "fullName"),
            (account, "created_at", "accountCreatedAt"),
            (org, "name", "organizationName"),
            (org, "organization_type", "organizationType"),
            (org, "billing_type", "billingType"),
            (org, "rate_limit_tier", "organizationRateLimitTier"),
            (org, "has_extra_usage_enabled", "hasExtraUsageEnabled"),
            (org, "subscription_created_at", "subscriptionCreatedAt"),
        ]
        for (source, from, to) in mapping {
            if let value = source[from], !(value is NSNull) { oauthAccount[to] = value }
        }
        return Profile(
            accountID: Account.id(accountUuid: accountUuid, organizationUuid: orgUuid),
            oauthAccount: oauthAccount,
            email: account["email"] as? String ?? "",
            organizationName: org["name"] as? String ?? ""
        )
    }

    static func usage(accessToken: String) async throws -> Usage {
        let root = try await get("api/oauth/usage", token: accessToken)
        func window(_ key: String) -> UsageWindow? {
            guard let json = root[key] as? JSON, let value = json["utilization"] as? NSNumber else { return nil }
            return UsageWindow(utilization: value.doubleValue, resetsAt: (json["resets_at"] as? String).flatMap(parseDate))
        }
        return Usage(fiveHour: window("five_hour"), sevenDay: window("seven_day"), fetchedAt: Date())
    }

    /// Exchanges the refresh token for a new token pair and returns an updated `claudeAiOauth`.
    static func refresh(_ oauth: JSON) async throws -> JSON {
        guard let refreshToken = oauth.refreshToken else { throw Failure.unauthorized }
        var body: JSON = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty {
            body["scope"] = scopes.joined(separator: " ")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 { throw Failure.unauthorized }
        guard status == 200 else { throw Failure.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? JSON,
              let access = json["access_token"] as? String else { throw Failure.malformed }

        var updated = oauth
        updated["accessToken"] = access
        if let newRefresh = json["refresh_token"] as? String { updated["refreshToken"] = newRefresh }
        if let expiresIn = json["expires_in"] as? NSNumber {
            updated["expiresAt"] = Int64((Date().timeIntervalSince1970 + expiresIn.doubleValue) * 1000)
        }
        if let scope = json["scope"] as? String, !scope.isEmpty {
            updated["scopes"] = scope.split(separator: " ").map(String.init)
        }
        return updated
    }

    private static func get(_ path: String, token: String) async throws -> JSON {
        var request = URLRequest(url: apiBase.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.unauthorized }
        guard status == 200 else { throw Failure.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? JSON else { throw Failure.malformed }
        return json
    }

    /// Handles timestamps like "2026-09-30T23:40:00.027100+00:00" (microsecond precision).
    static func parseDate(_ string: String) -> Date? {
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
