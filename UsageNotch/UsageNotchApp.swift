import SwiftUI

/// App entry point. There's no main window: everything lives in the notch panel,
/// which AppDelegate creates. The Dock icon is hidden via LSUIElement = YES
/// (set in the target's build settings → Info.plist).
@main
struct UsageNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A SwiftUI app needs at least one scene. Our real settings window is
        // SettingsWindowController (an app without a Dock icon has to show it itself).
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private lazy var settings = SettingsWindowController(store: store)

    /// Real data: one provider per AI you use. (For design work, swap in `UsageStore.fake(count: 2)`.)
    private let store = UsageStore(sources: [ClaudeCodeProvider()])

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.enableOnFirstInstalledLaunch()
        store.startPolling()
        notchController = NotchWindowController(store: store) { [weak self] in self?.settings.show() }
        notchController?.show()
    }

    /// Opening the app again (Spotlight, Finder) while it's already running shows Settings.
    /// That's also how you reach it when the pill is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }
}
