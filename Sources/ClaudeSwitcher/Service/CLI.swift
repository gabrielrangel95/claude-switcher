import Foundation

/// Terminal interface over the same AccountStore the app uses:
///   claude-switch list            show accounts and usage
///   claude-switch save            save the login Claude Code is using now
///   claude-switch <name|email>    switch (same as `switch <name>`)
enum CLI {
    static let commands: Set<String> = ["list", "status", "save", "switch", "help", "--help", "-h"]

    static func run(_ args: [String]) -> Never {
        Task { @MainActor in
            let code = await execute(args)
            exit(code)
        }
        dispatchMain()
    }

    @MainActor
    private static func execute(_ args: [String]) async -> Int32 {
        let store = AccountStore()
        await store.loadRecords()

        switch args.first {
        case "list", "status":
            await store.refresh()
            printAccounts(store)
        case "save":
            await store.saveCurrentLogin()
            guard store.lastError == nil, let account = store.activeAccount else { break }
            print("Saved \(account.label) (\(account.email)).")
        case "switch":
            guard args.count > 1 else {
                print("Usage: claude-switch switch <label or email>")
                return 64
            }
            let query = args.dropFirst().joined(separator: " ").lowercased()
            guard let account = match(query, in: store.accounts) else {
                print("No saved account matches “\(query)”. Saved: \(store.accounts.map(\.label).joined(separator: ", "))")
                return 1
            }
            await store.refresh()
            if store.activeID == account.id {
                print("Already using \(account.label).")
                return 0
            }
            await store.performSwitch(to: account.id)
            if store.lastError == nil { print("Switched to \(account.label) (\(account.email)). New claude sessions will use it.") }
        default:
            print("""
            claude-switch list             Show saved accounts and usage
            claude-switch save             Save the account Claude Code is logged in to
            claude-switch switch <name>    Switch Claude Code to a saved account
            """)
        }
        if let error = store.lastError {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            return 1
        }
        return 0
    }

    private static func match(_ query: String, in accounts: [Account]) -> Account? {
        accounts.first { $0.label.lowercased() == query || $0.email.lowercased() == query }
            ?? accounts.first { $0.label.lowercased().hasPrefix(query) || $0.email.lowercased().hasPrefix(query) }
    }

    @MainActor
    private static func printAccounts(_ store: AccountStore) {
        if store.accounts.isEmpty { print("No saved accounts. Run `claude-switch save` to add the current login.") }
        for account in store.accounts {
            let marker = account.id == store.activeID ? "●" : "○"
            var line = "\(marker) \(account.label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(account.email)"
            switch store.usage[account.id] {
            case .loaded(let usage):
                func describe(_ name: String, _ window: UsageWindow?) -> String {
                    guard let window else { return "\(name) —" }
                    let reset = window.resetsAt.map { " (resets \(Format.relative($0)))" } ?? ""
                    return "\(name) \(Format.percent(window.utilization))\(reset)"
                }
                line += "\n    " + describe("5h", usage.fiveHour) + "   " + describe("7d", usage.sevenDay)
            case .failed(let message):
                line += "\n    \(message)"
            default:
                break
            }
            print(line)
        }
        if let unsaved = store.unsavedLogin {
            print("○ (not saved)    \(unsaved.email) — run `claude-switch save`")
        }
    }
}
