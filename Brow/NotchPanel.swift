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
    private var appSwitchObserver: NSObjectProtocol?
    private let fullScreenCorners = FullScreenCorners()
    private let swipeTracker = SwipeTracker()
    /// True while the pill slides between the centred and shifted layouts.
    private var isShifting = false
    private lazy var menuWatcher = MenuBarWatcher { [weak self] in self?.checkMenus() }
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
                self?.learnSwipeDirection()
                self?.learnSideButton()
                // Mid slide, the corners wait for the pill to land (setShifted shows them).
                guard let self, self.state.isExpanded, !self.isShifting, SpaceInfo.isFullScreen else { return }
                self.showFullScreenCorners()
            }
        }
        // Switching apps: get the corners out of the way right as the switch starts (macOS
        // announces it before the screen moves), then bring them back once things settle,
        // if you've landed in a full screen app with the pill still open.
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isExpanded else { return }
                self.fullScreenCorners.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.state.isExpanded, !self.isShifting, SpaceInfo.isFullScreen else { return }
                        self.showFullScreenCorners()
                    }
                }
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
        // Slide over when the app in front has menus long enough to reach the pill,
        // following trackpad swipes between Spaces as they happen.
        menuWatcher.start()
        swipeTracker.onBegin = { [weak self] in self?.swipeBegan() }
        swipeTracker.onChange = { [weak self] in self?.swipeChanged($0) }
        swipeTracker.onEnd = { [weak self] in self?.swipeEnded(progress: $0, velocity: $1, cancelled: $2) }
        swipeTracker.onSideButton = { [weak self] in self?.sideButtonPressed($0) }
        swipeTracker.start()
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
        guard expand != state.isExpanded, panel != nil else { return }
        if expand {
            if SpaceInfo.isFullScreen { showFullScreenCorners() }
            // Grow the (invisible) window first, then let SwiftUI animate the pill into it.
            applyFrame(frame(expanded: true, shifted: state.isShifted))
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
                self.applyFrame(self.frame(expanded: false, shifted: self.state.isShifted))
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

    // MARK: Moving over for long menus

    /// Called by the menu watcher. Shifts right if the app in front's menus reach the left side.
    private func checkMenus() {
        guard let geometry, geometry.hasNotch, swipe == nil else { return } // a swipe is in charge
        // A switch is still landing: the app in front is still the one you're leaving.
        if let pendingSpace {
            guard SpaceInfo.activeID == pendingSpace else { return }
            self.pendingSpace = nil
        }
        let leftSideStart = geometry.notchRect.minX - NotchGeometry.earWidth
        let edge = MenuBarWatcher.menusRightEdge(leftOf: geometry.notchRect.minX, on: geometry.screen)
        let shifted = (edge ?? 0) > leftSideStart - 4
        spaceMemory[SpaceInfo.activeID] = shifted // remembered for swipes back to this Space
        setShifted(shifted)
    }

    /// Glides the pill to the centred (false) or moved right (true) layout, from wherever it is,
    /// including partway along after a swipe.
    private func setShifted(_ shifted: Bool, force: Bool = false) {
        let target: CGFloat = shifted ? 1 : 0
        guard force || shifted != state.isShifted || state.shiftProgress != target || isShifting else { return }
        let expanded = state.isExpanded
        // The corners sit in their own window and can't slide with the pill, so they fade out
        // for the move and come back once the pill has landed.
        isShifting = true
        if expanded { fullScreenCorners.hide() }
        state.isShifted = shifted
        // Make the window cover both places for the move, then fit it to where the pill lands.
        applyFrame(frame(expanded: expanded, shifted: false).union(frame(expanded: expanded, shifted: true)))
        withAnimation(Motion.shift(reduced: reduceMotion), completionCriteria: .logicallyComplete) {
            state.shiftProgress = target
        } completion: { [weak self] in
            guard let self, self.swipe == nil, self.state.shiftProgress == target else { return } // moved again meanwhile
            self.isShifting = false
            self.applyFrame(self.frame(expanded: self.state.isExpanded, shifted: shifted))
            if self.state.isExpanded, SpaceInfo.isFullScreen { self.showFullScreenCorners() }
        }
    }

    // MARK: Following a trackpad swipe

    /// How each Space looked last time you were there: moved right (true) or centred (false).
    /// Lets the pill know where it's heading before the swipe finishes.
    private var spaceMemory: [UInt64: Bool] = [:]

    private struct Swipe {
        var startShift: CGFloat
        var startSpace: UInt64
        var left: UInt64?
        var right: UInt64?
        var lastProgress: Double = 0
    }
    private var swipe: Swipe?          // fingers on the trackpad
    private var finishedSwipe: Swipe?  // fingers lifted, waiting to see if the Space changed
    /// Where the last swipe is taking you, until macOS confirms the switch. A quick second swipe
    /// starts from here, not from the Space you're leaving.
    private var pendingSpace: UInt64?
    /// Counts swipe ends, so only the latest one's follow-up check runs.
    private var swipeGeneration = 0

    /// Whether a positive swipe value means "towards the Space on the right". Learned from your
    /// first completed swipe, then saved.
    private var rightSign: Double {
        get { UserDefaults.standard.object(forKey: "swipeRightSign") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "swipeRightSign") }
    }

    private func swipeBegan() {
        guard let geometry, geometry.hasNotch, panel?.isVisible == true else { return }
        let start = pendingSpace ?? SpaceInfo.activeID
        let neighbours = SpaceInfo.neighbours(of: start)
        swipe = Swipe(startShift: state.shiftProgress, startSpace: start,
                      left: neighbours.left, right: neighbours.right)
        finishedSwipe = nil
        isShifting = true
        if state.isExpanded { fullScreenCorners.hide() }
        // Room for the pill anywhere between its two places while it follows your fingers.
        applyFrame(frame(expanded: state.isExpanded, shifted: false).union(frame(expanded: state.isExpanded, shifted: true)))
    }

    private func swipeChanged(_ progress: Double) {
        guard var current = swipe else { return }
        current.lastProgress = progress
        swipe = current
        let destination = progress * rightSign > 0 ? current.right : current.left
        // Heading somewhere Brow hasn't seen yet (or nowhere): stay put, it settles after the switch.
        let target = destination.flatMap { spaceMemory[$0] }.map { $0 ? CGFloat(1) : 0 } ?? current.startShift
        let amount = CGFloat(min(abs(progress), 1))
        // No animation: the pill moves exactly with your fingers. (Not disablesAnimations, which
        // would also stop the logo gliding across when the pill passes halfway.)
        state.shiftProgress = current.startShift + (target - current.startShift) * amount
    }

    /// Fingers lifted. Rather than wait for macOS to announce the switch (up to a second later),
    /// guess what the Dock will do, the way it decides: past halfway, or a quick flick that way.
    private func swipeEnded(progress: Double, velocity: Double, cancelled: Bool) {
        guard var ended = swipe else { return }
        swipe = nil
        ended.lastProgress = progress
        finishedSwipe = ended

        let flicked = abs(velocity) > 0.8 && velocity * progress > 0
        let willSwitch = !cancelled && (abs(progress) >= 0.5 || flicked)
        let destination = progress * rightSign > 0 ? ended.right : ended.left
        pendingSpace = willSwitch ? destination : nil
        if willSwitch, let destination, let remembered = spaceMemory[destination] {
            setShifted(remembered, force: true) // finish the move together with the Dock
        } else if !willSwitch {
            setShifted(state.isShifted, force: true) // let go: glide back
        }
        // Check the guess once things have settled. The menu check looks at where you really
        // are and corrects the pill if the guess was wrong. Only the latest swipe's check runs.
        swipeGeneration += 1
        let generation = swipeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.swipe == nil, self.swipeGeneration == generation else { return }
                self.pendingSpace = nil
                self.checkMenus()
            }
        }
    }

    // MARK: Mouse buttons 4 and 5

    /// A side button press that might switch Space: which button, from which Space, and its
    /// left and right neighbours. Kept briefly to learn what the button does.
    private var sideButtonPress: (button: Int64, space: UInt64, left: UInt64?, right: UInt64?)?

    /// Which way each side button switches Spaces (1 = right, -1 = left), learned from use.
    /// Forgotten if a press doesn't switch Space (e.g. it's Back and Forward in a browser).
    private func sideButtonDirection(_ button: Int64) -> Double? {
        UserDefaults.standard.object(forKey: "sideButton\(button)Direction") as? Double
    }

    private func setSideButtonDirection(_ button: Int64, _ direction: Double?) {
        UserDefaults.standard.set(direction, forKey: "sideButton\(button)Direction")
    }

    private func sideButtonPressed(_ button: Int64) {
        guard let geometry, geometry.hasNotch, panel?.isVisible == true, swipe == nil else { return }
        let start = pendingSpace ?? SpaceInfo.activeID
        let neighbours = SpaceInfo.neighbours(of: start)
        sideButtonPress = (button, start, neighbours.left, neighbours.right)

        // Known button heading somewhere Brow remembers: start moving with the switch.
        if let direction = sideButtonDirection(button),
           let destination = direction > 0 ? neighbours.right : neighbours.left,
           let remembered = spaceMemory[destination] {
            pendingSpace = destination
            setShifted(remembered, force: true)
        }
        swipeGeneration += 1
        let generation = swipeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.swipeGeneration == generation else { return }
                // No Space change followed: this button isn't a Space switch, forget it.
                if let press = self.sideButtonPress, SpaceInfo.activeID == press.space {
                    self.setSideButtonDirection(press.button, nil)
                }
                self.sideButtonPress = nil
                self.pendingSpace = nil
                self.checkMenus()
            }
        }
    }

    /// After a side button press that switched Space: learn which way that button goes.
    private func learnSideButton() {
        guard let press = sideButtonPress else { return }
        sideButtonPress = nil
        let now = SpaceInfo.activeID
        if now == press.right {
            setSideButtonDirection(press.button, 1)
        } else if now == press.left {
            setSideButtonDirection(press.button, -1)
        }
        swipeTracker.log("side button \(press.button) switched space, direction \(sideButtonDirection(press.button) ?? 0)")
    }

    /// After a swipe that switched Space: learn which way is right from where it went.
    private func learnSwipeDirection() {
        guard let done = finishedSwipe, done.lastProgress != 0 else { return }
        finishedSwipe = nil
        let now = SpaceInfo.activeID
        let sign: Double = done.lastProgress > 0 ? 1 : -1
        if now == done.right {
            rightSign = sign
        } else if now == done.left {
            rightSign = -sign
        }
        swipeTracker.log("switched space, right sign now \(rightSign)")
    }

    private func showFullScreenCorners() {
        guard let geometry, geometry.hasNotch else { return }
        fullScreenCorners.show(pill: frame(expanded: false, shifted: state.isShifted), radius: geometry.topFlare)
    }

    // MARK: Layout

    /// The window is anchored to the top of the screen around the pill.
    /// While open it gets extra room on both sides for the shadow and glow.
    private func frame(expanded: Bool, shifted: Bool) -> CGRect {
        guard let geometry else { return .zero }
        let notch = geometry.notchRect
        let margin = expanded ? PillLayout.openMargin : 0
        let minX = geometry.pillMinX(expanded: expanded, shifted: shifted) - margin
        let width = geometry.width(expanded: expanded, shifted: shifted) + margin * 2
        let height = expanded ? PillLayout.expandedWindowHeight : notch.height
        return CGRect(x: minX, y: notch.maxY - height, width: width, height: height)
    }

    /// Resizes the window and tells the view where it now starts, without animating that part.
    /// The pill is placed in screen coordinates, so it doesn't move when the window does.
    private func applyFrame(_ rect: CGRect) {
        guard let panel else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { state.windowMinX = rect.minX }
        panel.setFrame(rect, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func layout() {
        guard let geometry = NotchGeometry.current() else { return }
        self.geometry = geometry
        let frame = frame(expanded: state.isExpanded, shifted: state.isShifted)
        state.windowMinX = frame.minX

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
