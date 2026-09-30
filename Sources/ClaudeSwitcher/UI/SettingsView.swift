import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings().tabItem { Label("Accounts", systemImage: "person.2") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 360)
    }
}

private struct AccountsSettings: View {
    @EnvironmentObject var store: AccountStore
    @State private var pendingRemoval: Account?

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(store.accounts) { account in
                    AccountSettingsRow(account: account) { pendingRemoval = account }
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            HStack {
                Button("Log in to another account…") { store.beginAddAccount() }
                Button("Save current login") { Task { await store.saveCurrentLogin() } }
                Spacer()
            }
            Text("Drag to reorder. Removing an account only deletes this app's copy of its login.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .confirmationDialog(
            "Remove \(pendingRemoval?.label ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let account = pendingRemoval { store.remove(account.id) }
            }
        }
    }
}

private struct AccountSettingsRow: View {
    @EnvironmentObject var store: AccountStore
    let account: Account
    let onRemove: () -> Void
    @State private var label = ""

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(Palette.colors.indices, id: \.self) { index in
                    Button(Palette.names[index]) {
                        var updated = account
                        updated.colorIndex = index
                        store.update(updated)
                    }
                }
            } label: {
                AccountDot(color: account.color, size: 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                TextField("Label", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Text("\(account.email) · \(account.organizationName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .onAppear { label = account.label }
        .onChange(of: label) { save() }
    }

    private func save() {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != account.label else { return }
        var updated = account
        updated.label = trimmed
        store.update(updated)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var notch: NotchController
    @AppStorage("showNotch", store: Defaults.shared) private var showNotch = true
    @AppStorage("pollIntervalMinutes", store: Defaults.shared) private var pollInterval = 5.0
    @AppStorage("warnEnabled", store: Defaults.shared) private var warnEnabled = true
    @AppStorage("warnThreshold", store: Defaults.shared) private var warnThreshold = 90.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Show notch panel", isOn: $showNotch)
                .onChange(of: showNotch) { notch.setEnabled(showNotch) }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }

            Picker("Refresh usage every", selection: $pollInterval) {
                Text("2 minutes").tag(2.0)
                Text("5 minutes").tag(5.0)
                Text("10 minutes").tag(10.0)
                Text("30 minutes").tag(30.0)
            }
            .onChange(of: pollInterval) { store.schedulePolling() }

            Toggle("Notify when the active account gets close to a limit", isOn: $warnEnabled)
            if warnEnabled {
                Slider(value: $warnThreshold, in: 50...99, step: 1) {
                    Text("Notify at \(Int(warnThreshold))%")
                }
            }

            LabeledContent("~/.claude.json") {
                Button("Restore from backup") { store.restoreConfigBackup() }
                    .disabled(!ClaudeCode.hasBackup)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            store.lastError = "Launch at login: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
