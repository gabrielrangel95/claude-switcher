import SwiftUI

struct ClaudeSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(delegate.store)
        } label: {
            MenuBarLabel()
                .environmentObject(delegate.store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(delegate.store)
                .environmentObject(delegate.notch)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AccountStore()
    lazy var notch = NotchController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.start()
        notch.setEnabled(Defaults.shared.object(forKey: "showNotch") as? Bool ?? true)
    }
}
