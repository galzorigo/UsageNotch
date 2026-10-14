import AppKit
import ApplicationServices

/// Finds out how far the app in front's menus reach along the menu bar, so the pill can move
/// out of their way. macOS keeps menus out of the hardware notch, but it doesn't know about the
/// pill, so apps with many menus (File Edit View Tabs Bookmarks…) end up underneath its left side.
///
/// Reading another app's menu positions needs the Accessibility permission
/// (System Settings → Privacy & Security → Accessibility). Without it, nothing moves.
@MainActor
final class MenuBarWatcher {
    private let onCheck: () -> Void
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    /// `onCheck` is called whenever the menus may have changed. It then asks `menusRightEdge`.
    init(onCheck: @escaping () -> Void) {
        self.onCheck = onCheck
    }

    func start() {
        Self.askForPermissionOnce()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSoon() }
            })
        }
        // Some apps change their menus without switching apps (a different kind of window).
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onCheck() }
        }
        checkSoon()
    }

    /// Menus can take a moment to appear after an app comes to the front: check now and again shortly.
    private func checkSoon() {
        onCheck()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.onCheck() }
        }
    }

    // MARK: Permission

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "allow Accessibility" prompt, only the very first time.
    private static func askForPermissionOnce() {
        let key = "didAskForAccessibility"
        guard !hasPermission, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Reading the menus

    /// The right edge (screen x) of the last menu that sits left of `notchMinX` on `screen`,
    /// for the app in front. nil when unknown (no permission, our own app, nothing readable).
    static func menusRightEdge(leftOf notchMinX: CGFloat, on screen: NSScreen) -> CGFloat? {
        guard hasPermission,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25) // never hang on a busy app
        guard let menuBar = attribute(appElement, kAXMenuBarAttribute),
              let items = attribute(menuBar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return nil }

        var edge: CGFloat?
        for item in items {
            guard let position = point(item), let size = size(item), size.width > 0,
                  position.x >= screen.frame.minX, position.x < notchMinX else { continue }
            edge = max(edge ?? 0, position.x + size.width)
        }
        return edge
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func point(_ element: AXUIElement) -> CGPoint? {
        guard let value = attribute(element, kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        guard let value = attribute(element, kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
