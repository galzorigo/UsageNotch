import AppKit
import ServiceManagement
import SwiftUI

/// "Open at login", using macOS's built-in login items (System Settings → General → Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("UsageNotch: login item change failed: \(error)")
        }
    }

    /// The first time the installed app runs, turn "Open at login" on so the pill is always there.
    /// Only once: if you switch it off later, it stays off.
    static func enableOnFirstInstalledLaunch() {
        let key = "didSetUpLoginItem"
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        set(true)
        UserDefaults.standard.set(true, forKey: key)
    }
}

/// The small settings window: which AIs to show, open at login, quit.
struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Show in the notch") {
                Toggle(isOn: binding(for: .claude)) {
                    Label { Text("Claude") } icon: { ProviderIcon(kind: .claude) }
                }
                Toggle(isOn: .constant(false)) {
                    Label { Text("Codex") } icon: { ProviderIcon(kind: .codex) }
                    Text("Not connected yet")
                }
                .disabled(true)
            }
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, wanted in
                        LoginItem.set(wanted)
                        openAtLogin = LoginItem.isEnabled // reflect what actually happened
                    }
            } footer: {
                Text("The pill hides itself when you have no active plan.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Quit UsageNotch") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize()
    }

    private func binding(for kind: ProviderKind) -> Binding<Bool> {
        Binding(
            get: { store.enabledKinds.contains(kind) },
            set: { on in
                if on { store.enabledKinds.insert(kind) } else { store.enabledKinds.remove(kind) }
            }
        )
    }
}

/// Owns the settings window. Our app has no Dock icon or menu bar, so we show it ourselves.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: UsageStore

    init(store: UsageStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            window.title = "UsageNotch"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true) // bring it in front of other apps
        window?.makeKeyAndOrderFront(nil)
    }
}
