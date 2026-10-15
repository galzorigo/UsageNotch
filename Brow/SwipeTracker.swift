import AppKit

/// Follows trackpad swipes between Spaces as they happen, so the pill can move with your fingers.
///
/// macOS has no public way to know a Space swipe is in progress. The Dock drives that animation
/// from "dock swipe" trackpad events, and this listens to copies of them. It's listen only:
/// events reach your apps exactly as before, never waiting on Brow. The event fields used here
/// are undocumented, so if a macOS update changes them, Brow simply goes back to moving once
/// the switch has finished.
///
/// To see what it receives, turn on a log at ~/Library/Logs/Brow/swipe.log with:
/// defaults write com.galzorigoo.Brow logSwipes -bool true
@MainActor
final class SwipeTracker {
    /// A swipe started.
    var onBegin: () -> Void = {}
    /// Mouse button 4 or 5 pressed (buttonNumber 3 or 4). Often set up to switch Spaces.
    var onSideButton: (_ button: Int64) -> Void = { _ in }
    /// How far along it is: 0 at the start, about ±1 for a whole Space. The sign is the direction.
    var onChange: (Double) -> Void = { _ in }
    /// Fingers lifted, with where they were, how fast they were moving (progress per second, same
    /// sign as progress) and whether macOS cancelled the swipe. The Dock then decides whether the
    /// switch happens.
    var onEnd: (_ progress: Double, _ velocity: Double, _ cancelled: Bool) -> Void = { _, _, _ in }

    private var taps: [CFMachPort] = []
    /// The same event arrives from both listening points, a moment apart: handle each one once.
    private var lastEvent: (phase: Int64, progress: Double, time: TimeInterval)?
    /// Recent (time, progress) pairs, to measure how fast your fingers were moving at the end.
    private var recent: [(time: TimeInterval, progress: Double)] = []

    // Undocumented event details (from how open source tools post their own Space swipes).
    private static let dockControlType: UInt32 = 30   // event type for Dock gestures
    private static let gestureKindField: UInt32 = 110 // which gesture it is
    private static let dockSwipeKind: Int64 = 23      // kIOHIDEventTypeDockSwipe
    private static let phaseField: UInt32 = 132       // 1 began, 2 changed, 4 ended, 8 cancelled
    private static let progressField: UInt32 = 124    // swipe progress

    /// Watching trackpad events needs Input Monitoring (System Settings → Privacy & Security).
    /// Without it macOS sets up the listener but never sends it anything.
    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    func start() {
        guard taps.isEmpty else { return }
        if !Self.hasPermission {
            log("No Input Monitoring permission yet. Asking.")
            _ = CGRequestListenEventAccess() // shows macOS's own prompt
        }
        // The login session level sees the Dock's swipe events (so does HID, which only doubled them).
        if let tap = makeTap(at: .cgSessionEventTap) {
            taps.append(tap)
            log("Listening for swipes.")
        } else {
            log("Couldn't listen for swipes.")
        }
    }

    private func makeTap(at location: CGEventTapLocation) -> CFMachPort? {
        let mask: CGEventMask = (1 << CGEventMask(Self.dockControlType))
            | (1 << CGEventMask(CGEventType.otherMouseDown.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, info in
            if let info {
                let tracker = Unmanaged<SwipeTracker>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { tracker.handle(type: type, event: event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return tap
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS switches a listener off if it ever takes too long. Switch it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            for tap in taps { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .otherMouseDown {
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if button == 3 || button == 4 { onSideButton(button) }
            return
        }
        guard type.rawValue == Self.dockControlType,
              event.getIntegerValueField(Self.field(Self.gestureKindField)) == Self.dockSwipeKind else { return }

        let phase = event.getIntegerValueField(Self.field(Self.phaseField))
        let progress = event.getDoubleValueField(Self.field(Self.progressField))
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastEvent, last.phase == phase, last.progress == progress, now - last.time < 0.02 { return }
        lastEvent = (phase, progress, now)

        switch phase {
        case 1:
            recent = [(now, progress)]
            onBegin()
            armWatchdog()
        case 2:
            armWatchdog()
            lastProgress = progress
            recent.append((now, progress))
            recent.removeAll { now - $0.time > 0.08 } // the last 80ms is "how fast it's moving"
            onChange(progress)
        case 4, 8:
            let velocity = Self.velocity(recent + [(now, progress)])
            log("end phase \(phase) progress \(String(format: "%.3f", progress)) velocity \(String(format: "%.2f", velocity))")
            recent = []
            watchdog?.invalidate()
            onEnd(progress, velocity, phase == 8)
        default: break
        }
    }

    /// If macOS ever drops a swipe's last event, end it after a second of silence, treated as
    /// cancelled, so the pill never stays stuck waiting for it.
    private var watchdog: Timer?
    private var lastProgress: Double = 0

    private func armWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log("swipe went quiet, ending it")
                self.recent = []
                self.onEnd(self.lastProgress, 0, true)
            }
        }
    }

    private static func velocity(_ samples: [(time: TimeInterval, progress: Double)]) -> Double {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.005 else { return 0 }
        return (last.progress - first.progress) / (last.time - first.time)
    }

    private static func field(_ raw: UInt32) -> CGEventField {
        unsafeBitCast(raw, to: CGEventField.self)
    }

    // MARK: Log

    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Brow/swipe.log")
    private var loggedLines = 0

    func log(_ line: String) {
        guard UserDefaults.standard.bool(forKey: "logSwipes"), loggedLines < 3000 else { return }
        loggedLines += 1
        let url = Self.logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "\(Date().formatted(.iso8601)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
