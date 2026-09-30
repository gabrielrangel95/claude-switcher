import SwiftUI

struct MenuView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Claude accounts").font(.headline)
                Spacer()
                if let last = store.lastRefresh {
                    Text(last, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh usage")
            }

            if store.accounts.isEmpty && store.unsavedLogin == nil {
                Text("No accounts yet. Save the account Claude Code is logged in to, then add the others.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(store.accounts) { account in
                AccountRow(account: account)
            }

            if let unsaved = store.unsavedLogin {
                UnsavedLoginRow(login: unsaved)
            }

            if store.isAddingAccount {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish the login in Terminal…").font(.callout)
                    Spacer()
                    Button("Cancel") { store.cancelAddAccount() }.buttonStyle(.borderless)
                }
            }

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { store.lastError = nil }
            }

            Divider()

            HStack {
                Menu("Add account") {
                    Button("Log in to another account…") { store.beginAddAccount() }
                    Button("Save current Claude Code login") { Task { await store.saveCurrentLogin() } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(store.isAddingAccount)

                Spacer()

                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .buttonStyle(.borderless)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .font(.callout)

            Text("Switching applies to new `claude` sessions.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct AccountRow: View {
    @EnvironmentObject var store: AccountStore
    let account: Account

    private var isActive: Bool { store.activeID == account.id }
    private var state: UsageState? { store.usage[account.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                AccountDot(color: account.color, size: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.label).font(.body.weight(.semibold))
                    Text(account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isActive {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(account.color.opacity(0.2), in: Capsule())
                        .foregroundStyle(account.color)
                } else if store.switchingTo == account.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Switch") { store.switchTo(account.id) }
                        .controlSize(.small)
                        .disabled(store.switchingTo != nil)
                }
            }

            switch state {
            case .loaded(let usage):
                UsageBar(title: "5-hour", window: usage.fiveHour)
                UsageBar(title: "Weekly", window: usage.sevenDay)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.secondary)
            case .loading, nil:
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? account.color.opacity(0.08) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isActive ? account.color.opacity(0.5) : .clear, lineWidth: 1)
        )
    }
}

private struct UnsavedLoginRow: View {
    @EnvironmentObject var store: AccountStore
    let login: AccountStore.UnsavedLogin

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Current login isn't saved").font(.callout.weight(.medium))
                Text(login.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Save") { Task { await store.saveCurrentLogin() } }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

/// Menu bar label: active account name and its 5-hour usage.
struct MenuBarLabel: View {
    @EnvironmentObject var store: AccountStore

    var body: some View {
        if let account = store.activeAccount {
            let percent = store.usage[account.id]?.usage?.fiveHour.map { " \(Format.percent($0.utilization))" } ?? ""
            Text("✳︎ \(account.label)\(percent)")
        } else {
            Text("✳︎ Claude")
        }
    }
}
