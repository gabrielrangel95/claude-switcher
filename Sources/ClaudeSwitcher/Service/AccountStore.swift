import AppKit
import Foundation
import UserNotifications

/// Central state: saved accounts, which one Claude Code is using, per-account usage, and the
/// switch / add-account flows. All mutations of Claude Code's state go through `serialized`.
@MainActor
final class AccountStore: ObservableObject {
    struct UnsavedLogin: Equatable {
        var id: String
        var email: String
        var organizationName: String
    }

    struct PendingLogin {
        var previousAccessToken: String?
        var startedAt: Date
    }

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var usage: [String: UsageState] = [:]
    @Published private(set) var activeID: String?
    @Published private(set) var unsavedLogin: UnsavedLogin?
    @Published private(set) var switchingTo: String?
    @Published private(set) var isAddingAccount = false
    @Published private(set) var lastRefresh: Date?
    @Published var lastError: String?

    var activeAccount: Account? { accounts.first { $0.id == activeID } }

    private var records: [String: VaultRecord] = [:]
    private var identityByAccessToken: [String: String] = [:]
    private var lastSeenLiveAccessToken: String?
    private var pendingLogin: PendingLogin?
    private var notifiedWindows: Set<String> = []
    private var tail: Task<Void, Never>?
    private var watchTimer: Timer?
    private var pollTimer: Timer?

    private let defaults = Defaults.shared
    private static let accountsKey = "accounts"

    var pollInterval: TimeInterval {
        let value = defaults.double(forKey: "pollIntervalMinutes")
        return (value > 0 ? value : 5) * 60
    }

    var warnThreshold: Double {
        let value = defaults.double(forKey: "warnThreshold")
        return value > 0 ? value : 90
    }

    var warnEnabled: Bool { defaults.object(forKey: "warnEnabled") as? Bool ?? true }

    init() {
        if let data = defaults.data(forKey: Self.accountsKey),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = saved
        }
    }

    func start() {
        Task {
            await loadRecords()
            await refresh()
        }
        // Cheap check for logins changed outside the app (e.g. `/login` in a terminal).
        watchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkLiveLogin() }
        }
        schedulePolling()
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func loadRecords() async {
        let ids = accounts.map(\.id)
        let loaded = await Self.offMain { ids.compactMap { id in AccountVault.load(id).map { (id, $0) } } }
        records = Dictionary(loaded, uniquingKeysWith: { $1 })
    }

    func schedulePolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: Refresh

    /// Syncs the live login back into the vault, then fetches usage for every account.
    func refresh() async {
        await serialized {
            await self.syncLiveLogin()
            await self.fetchAllUsage()
            self.lastRefresh = Date()
        }
    }

    private func checkLiveLogin() async {
        let live = await Self.offMain { try? ClaudeCode.readLiveOAuth() }
        let token = live?.accessToken
        guard token != lastSeenLiveAccessToken else { return }

        if let pending = pendingLogin {
            if Date().timeIntervalSince(pending.startedAt) > 600 {
                pendingLogin = nil
                isAddingAccount = false
            } else if token != nil, token != pending.previousAccessToken {
                // Give Claude Code a moment to finish writing ~/.claude.json.
                try? await Task.sleep(for: .seconds(2))
                pendingLogin = nil
                await saveCurrentLogin()
                isAddingAccount = false
                return
            }
        }
        await refresh()
    }

    /// Figures out which account the live Keychain login belongs to and stores its latest tokens.
    private func syncLiveLogin() async {
        let live: JSON?
        do {
            live = try await Self.offMain { try ClaudeCode.readLiveOAuth() }
        } catch {
            lastError = error.localizedDescription
            return
        }
        lastSeenLiveAccessToken = live?.accessToken
        guard let live, let token = live.accessToken else {
            activeID = nil
            unsavedLogin = nil
            return
        }

        guard let id = await identify(live) else { return }
        activeID = id

        if var record = records[id] {
            unsavedLogin = nil
            var changed = false
            if record.oauth.accessToken != token || record.oauth.refreshToken != live.refreshToken {
                record.oauth = live
                changed = true
            }
            // Pick up fresher identity fields Claude Code wrote for this same account.
            if let configAccount = ClaudeCode.readOAuthAccount(), Account.id(fromOAuthAccount: configAccount) == id,
               !NSDictionary(dictionary: configAccount).isEqual(to: record.oauthAccount) {
                record.oauthAccount = configAccount
                changed = true
            }
            if changed { persist(record, id: id) }
        } else {
            let config = ClaudeCode.readOAuthAccount()
            let profile = try? await AnthropicAPI.profile(accessToken: token)
            unsavedLogin = UnsavedLogin(
                id: id,
                email: profile?.email ?? config?["emailAddress"] as? String ?? "Unknown",
                organizationName: profile?.organizationName ?? config?["organizationName"] as? String ?? ""
            )
        }
    }

    private func identify(_ live: JSON) async -> String? {
        guard let token = live.accessToken else { return nil }
        if let match = records.first(where: { $0.value.oauth.accessToken == token || $0.value.oauth.refreshToken == live.refreshToken }) {
            return match.key
        }
        if let cached = identityByAccessToken[token] { return cached }
        if let profile = try? await AnthropicAPI.profile(accessToken: token) {
            identityByAccessToken[token] = profile.accountID
            return profile.accountID
        }
        // Offline or token expired: trust the identity Claude Code wrote.
        return ClaudeCode.readOAuthAccount().flatMap(Account.id(fromOAuthAccount:))
    }

    private func fetchAllUsage() async {
        let active = activeID
        for account in accounts where usage[account.id] == nil { usage[account.id] = .loading }

        await withTaskGroup(of: (String, UsageState?, JSON?).self) { group in
            for account in accounts {
                guard let record = records[account.id] else {
                    usage[account.id] = .failed("Missing saved login — add this account again")
                    continue
                }
                let isActive = account.id == active
                group.addTask {
                    var oauth = record.oauth
                    var refreshed: JSON?
                    if oauth.expires(within: 120) {
                        // Claude Code owns the active login's refresh; never rotate it underneath it.
                        if isActive { return (account.id, nil, nil) }
                        do {
                            oauth = try await AnthropicAPI.refresh(oauth)
                            refreshed = oauth
                        } catch {
                            return (account.id, .failed(error.localizedDescription), nil)
                        }
                    }
                    guard let token = oauth.accessToken else {
                        return (account.id, .failed("Missing token"), refreshed)
                    }
                    do {
                        return (account.id, .loaded(try await AnthropicAPI.usage(accessToken: token)), refreshed)
                    } catch {
                        return (account.id, .failed(error.localizedDescription), refreshed)
                    }
                }
            }
            for await (id, state, refreshed) in group {
                if let refreshed, var record = records[id] {
                    record.oauth = refreshed
                    persist(record, id: id)
                }
                if let state {
                    // Keep showing the last good numbers when a single poll fails for a transient reason.
                    let expired = state == .failed(AnthropicAPI.Failure.unauthorized.localizedDescription)
                    if case .failed = state, usage[id]?.usage != nil, !expired { continue }
                    usage[id] = state
                } else if usage[id] == .loading {
                    usage[id] = .failed("Waiting for Claude Code to refresh this login")
                }
            }
        }
        checkWarnings()
    }

    // MARK: Switching

    func switchTo(_ id: String) {
        guard id != activeID, switchingTo == nil else { return }
        Task { await performSwitch(to: id) }
    }

    func performSwitch(to id: String) async {
        await serialized {
            self.switchingTo = id
            defer { self.switchingTo = nil }
            self.lastError = nil

            // 1. Save the current login's latest tokens before replacing them.
            await self.syncLiveLogin()

            guard var target = self.records[id], let account = self.accounts.first(where: { $0.id == id }) else {
                self.lastError = "No saved login for that account. Add it again."
                return
            }
            do {
                // 2. Hand Claude Code a token that won't expire right away.
                if target.oauth.expires(within: 600) {
                    target.oauth = try await AnthropicAPI.refresh(target.oauth)
                    self.persist(target, id: id)
                }
                // 3–4. Swap tokens (Keychain) and identity (~/.claude.json).
                let record = target
                try await Self.offMain {
                    try ClaudeCode.writeLiveOAuth(record.oauth)
                    try ClaudeCode.writeOAuthAccount(record.oauthAccount)
                }
                self.activeID = id
                self.unsavedLogin = nil
                self.lastSeenLiveAccessToken = target.oauth.accessToken
                if let token = target.oauth.accessToken { self.identityByAccessToken[token] = id }
                self.notify(title: "Claude: \(account.label)", body: "New claude sessions will use \(account.email).")
            } catch {
                self.lastError = "Switch failed: \(error.localizedDescription)"
                return
            }
            await self.fetchAllUsage()
        }
    }

    // MARK: Adding and editing accounts

    /// Saves whatever account Claude Code is logged in to right now.
    func saveCurrentLogin() async {
        await serialized {
            do {
                guard let live = try await Self.offMain({ try ClaudeCode.readLiveOAuth() }), let token = live.accessToken else {
                    self.lastError = "Claude Code isn't logged in. Run `claude auth login` first."
                    return
                }
                let profile = try await AnthropicAPI.profile(accessToken: token)
                var oauthAccount = profile.oauthAccount
                if let config = ClaudeCode.readOAuthAccount(), Account.id(fromOAuthAccount: config) == profile.accountID {
                    oauthAccount = config
                }
                self.persist(VaultRecord(oauth: live, oauthAccount: oauthAccount), id: profile.accountID)
                if !self.accounts.contains(where: { $0.id == profile.accountID }) {
                    self.accounts.append(Account(
                        id: profile.accountID,
                        label: Self.defaultLabel(organizationName: profile.organizationName, email: profile.email),
                        email: profile.email,
                        organizationName: profile.organizationName,
                        colorIndex: self.accounts.count
                    ))
                    self.saveAccounts()
                }
                self.identityByAccessToken[token] = profile.accountID
                self.activeID = profile.accountID
                self.unsavedLogin = nil
                self.lastSeenLiveAccessToken = token
            } catch {
                self.lastError = "Couldn't save this login: \(error.localizedDescription)"
            }
            await self.fetchAllUsage()
        }
    }

    /// Opens a Terminal window running `claude auth login`; the new login is saved automatically.
    func beginAddAccount() {
        Task {
            await refresh()  // store the current account's latest tokens first
            let script = """
            #!/bin/zsh -l
            clear
            echo "Claude Switcher — log in with the account you want to add."
            echo "Your current account stays saved; switch back from the menu bar afterwards."
            echo
            claude auth login
            echo
            echo "Done. You can close this window."
            """
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-switcher-login.command")
            do {
                try script.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            } catch {
                lastError = error.localizedDescription
                return
            }
            pendingLogin = PendingLogin(previousAccessToken: lastSeenLiveAccessToken, startedAt: Date())
            isAddingAccount = true
            NSWorkspace.shared.open(url)
        }
    }

    func cancelAddAccount() {
        pendingLogin = nil
        isAddingAccount = false
    }

    func update(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        saveAccounts()
    }

    func move(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        saveAccounts()
    }

    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        records[id] = nil
        usage[id] = nil
        AccountVault.delete(id)
        saveAccounts()
        if activeID == id {
            Task { await refresh() }
        }
    }

    func restoreConfigBackup() {
        do {
            try ClaudeCode.restoreBackup()
            Task { await refresh() }
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    private func persist(_ record: VaultRecord, id: String) {
        records[id] = record
        do {
            try AccountVault.save(record, id: id)
        } catch {
            lastError = "Couldn't save login to Keychain: \(error.localizedDescription)"
        }
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.accountsKey)
        }
    }

    private func checkWarnings() {
        guard warnEnabled, let account = activeAccount, let usage = usage[account.id]?.usage else { return }
        for (name, window) in [("5-hour", usage.fiveHour), ("weekly", usage.sevenDay)] {
            guard let window, window.utilization >= warnThreshold else { continue }
            let key = "\(account.id):\(name):\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
            guard !notifiedWindows.contains(key) else { continue }
            notifiedWindows.insert(key)
            let reset = window.resetsAt.map { " Resets \(Format.relative($0))." } ?? ""
            notify(title: "\(account.label): \(Int(window.utilization))% of \(name) limit", body: "Heads up.\(reset)")
        }
    }

    private func notify(title: String, body: String) {
        // UserNotifications requires running from the .app bundle (not the bare CLI binary).
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Runs operations that touch Claude Code's state one at a time.
    private func serialized(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
    }

    nonisolated private static func offMain<T>(_ work: @escaping () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    nonisolated private static func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private static func defaultLabel(organizationName: String, email: String) -> String {
        if organizationName.isEmpty || organizationName.hasSuffix("'s Organization") || organizationName.contains("@") {
            return "Personal"
        }
        return organizationName
    }
}
