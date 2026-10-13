import AppKit
import Combine
import SwiftUI

/// A borderless, see-through window that floats above the menu bar.
/// .nonactivatingPanel means clicking it won't pull focus away from the app you're using.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        // Apps draw their menu bar contents in a full-width strip at .statusBar + 1 (layer 26),
        // so we sit one above that (27). Dropdown menus (layer 101) still open over us.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        // .fullScreenAuxiliary lets it show over full-screen apps too. On a notched Mac
        // the strip above a full-screen app is black, so the pill blends right in.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Normal windows get pushed below the menu bar. This one is allowed to sit on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Lets the very first click land, even though our panel never becomes the active window.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Creates the panel, sizes it around the notch, opens/closes it, re-measures when displays
/// change, and hides it entirely when there's no AI in use.
@MainActor
final class NotchWindowController {
    private let store: UsageStore
    private let openSettings: () -> Void
    private let state = NotchState()
    private var geometry: NotchGeometry?
    private var panel: NotchPanel?
    private let stickySpace = StickySpace()
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private let fullScreenCorners = FullScreenCorners()
    private var outsideClickMonitor: Any?
    private var visibilityObserver: AnyCancellable?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(store: UsageStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
    }

    func show() {
        layout()
        // Arriving in a full screen app with the pill open: round off the strip there too.
        // (Leaving one needs nothing: its corners slide away with it.)
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isExpanded, SpaceInfo.isFullScreen, let geometry = self.geometry else { return }
                self.fullScreenCorners.show(geometry: geometry)
            }
        }
        // Plugging in a monitor, changing resolution, or opening the lid fires this.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setExpanded(false, animated: false)
                self?.layout()
            }
        }
        // Show the pill only while at least one AI is in use. Re-checked on every refresh,
        // so it comes back by itself when you start using Claude again.
        visibilityObserver = Publishers.CombineLatest(store.$providers, store.$enabledKinds)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateVisibility(anyActive: !self.store.activeProviders.isEmpty)
                }
            }
    }

    private func updateVisibility(anyActive: Bool) {
        guard let panel else { return }
        if anyActive {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            setExpanded(false, animated: false)
            panel.orderOut(nil) // gone: the notch looks completely normal
        }
    }

    // MARK: Open / close

    private func toggle() {
        setExpanded(!state.isExpanded, animated: true)
    }

    private func setExpanded(_ expand: Bool, animated: Bool) {
        guard expand != state.isExpanded, let panel else { return }
        if expand {
            if SpaceInfo.isFullScreen, let geometry { fullScreenCorners.show(geometry: geometry) }
            // Grow the (invisible) window first, then let SwiftUI animate the pill into it.
            panel.setFrame(frame(expanded: true), display: false)
            // Re-centre the content in the bigger window *now*, outside the animation.
            // Otherwise SwiftUI animates that re-centring too and everything slides sideways.
            panel.contentView?.layoutSubtreeIfNeeded()
            withAnimation(animated ? Motion.open(reduced: reduceMotion) : nil) {
                state.isExpanded = true
            }
            startWatchingOutsideClicks()
        } else {
            stopWatchingOutsideClicks()
            fullScreenCorners.hide()
            // Animate the pill closed, then shrink the window so it stops covering the menu bar.
            withAnimation(animated ? Motion.close(reduced: reduceMotion) : nil, completionCriteria: .logicallyComplete) {
                state.isExpanded = false
            } completion: { [weak self] in
                guard let self, !self.state.isExpanded else { return } // reopened mid-animation
                panel.setFrame(self.frame(expanded: false), display: true)
            }
        }
    }

    /// Clicks in other apps close the pill. Mouse clicks don't need any special permission.
    private func startWatchingOutsideClicks() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setExpanded(false, animated: true) }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    // MARK: Layout

    /// The window is anchored to the top of the screen, centred on the notch.
    private func frame(expanded: Bool) -> CGRect {
        guard let geometry else { return .zero }
        let notch = geometry.notchRect
        // While open, add room on both sides for the shadow. The pill stays centred.
        let width = geometry.width(expanded: expanded) + (expanded ? PillLayout.shadowMargin * 2 : 0)
        let height = expanded ? PillLayout.expandedWindowHeight : notch.height
        return CGRect(x: notch.midX - width / 2, y: notch.maxY - height, width: width, height: height)
    }

    private func layout() {
        guard let geometry = NotchGeometry.current() else { return }
        self.geometry = geometry
        let frame = frame(expanded: state.isExpanded)

        let panel = panel ?? NotchPanel(contentRect: frame)
        let view = NotchView(geometry: geometry, store: store, state: state,
                             onTap: { [weak self] in self?.toggle() },
                             onSettings: { [weak self] in
                                 self?.setExpanded(false, animated: false)
                                 self?.openSettings()
                             })
        let hosting = FirstClickHostingView(rootView: view)
        hosting.sizingOptions = [] // the window decides the size, not SwiftUI
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        if store.activeProviders.isEmpty {
            panel.orderOut(nil) // nothing to show (yet): stay hidden
        } else {
            panel.orderFrontRegardless() // show without activating the app
        }
        if self.panel == nil { stickySpace.add(panel) } // only once, on first creation
        self.panel = panel
    }
}
