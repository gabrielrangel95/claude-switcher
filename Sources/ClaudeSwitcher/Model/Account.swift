import SwiftUI

/// Non-secret metadata for a saved account. Persisted in UserDefaults; tokens live in the Keychain.
struct Account: Codable, Identifiable, Equatable {
    /// "<accountUuid>:<organizationUuid>" — one login can belong to several orgs.
    let id: String
    var label: String
    var email: String
    var organizationName: String
    var colorIndex: Int

    var color: Color { Palette.colors[colorIndex % Palette.colors.count] }

    static func id(accountUuid: String, organizationUuid: String) -> String {
        "\(accountUuid):\(organizationUuid)"
    }

    static func id(fromOAuthAccount json: JSON) -> String? {
        guard let account = json["accountUuid"] as? String,
              let org = json["organizationUuid"] as? String else { return nil }
        return id(accountUuid: account, organizationUuid: org)
    }
}

enum Palette {
    static let colors: [Color] = [.orange, .blue, .green, .purple, .pink, .teal]
    static let names = ["Orange", "Blue", "Green", "Purple", "Pink", "Teal"]
}

struct UsageWindow: Equatable {
    var utilization: Double   // 0–100
    var resetsAt: Date?
}

struct Usage: Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var fetchedAt: Date
}

enum UsageState: Equatable {
    case loading
    case loaded(Usage)
    case failed(String)

    var usage: Usage? {
        if case .loaded(let usage) = self { return usage }
        return nil
    }
}
