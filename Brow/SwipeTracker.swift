import AppKit

/// Follows trackpad swipes between Spaces as they happen, so the pill can move with your fingers.
///
/// macOS has no public way to know a Space swipe is in progress. The Dock drives that animation
/// from "dock swipe" trackpad events, and this listens to copies of them. It's listen only:
/// events reach your apps exactly as before, never waiting on Brow. The event fields used here
/// are undocumented, so if a macOS update changes them, Brow simply goes back to moving once
/// the switch has finished.
///
/// While this is new, every swipe is written to ~/Library/Logs/Brow/swipe.log so the numbers
/// can be checked. Turn it off with: defaults write com.galzorigoo.Brow logSwipes -bool false
@MainActor
final class SwipeTracker {
    /// A swipe started.
    var onBegin: () -> Void = {}
    /// How far along it is: 0 at the start, about ±1 for a whole Space. The sign is the direction.
    var onChange: (Double) -> Void = { _ in }
    /// Fingers lifted (or the swipe was cancelled). The Dock decides whether the switch happens.
    var onEnd: () -> Void = {}

    private var tap: CFMachPort?

    // Undocumented event details (from how open source tools post their own Space swipes).
    private static let dockControlType: UInt32 = 30   // event type for Dock gestures
    private static let gestureKindField: UInt32 = 110 // which gesture it is
    private static let dockSwipeKind: Int64 = 23      // kIOHIDEventTypeDockSwipe
    private static let phaseField: UInt32 = 132       // 1 began, 2 changed, 4 ended, 8 cancelled
    private static let progressField: UInt32 = 124    // swipe progress

    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << 29) | (1 << CGEventMask(Self.dockControlType))
        let callback: CGEventTapCallBack = { _, type, event, info in
            if let info {
                let tracker = Unmanaged<SwipeTracker>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { tracker.handle(type: type, event: event) }
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            log("Couldn't listen for swipes (permission?). Moving after the switch instead.")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("Listening for swipes.")
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS switches a listener off if it ever takes too long. Switch it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type.rawValue == Self.dockControlType,
              event.getIntegerValueField(Self.field(Self.gestureKindField)) == Self.dockSwipeKind else { return }

        let phase = event.getIntegerValueField(Self.field(Self.phaseField))
        let progress = event.getDoubleValueField(Self.field(Self.progressField))
        log("phase \(phase) progress \(String(format: "%.3f", progress))")

        switch phase {
        case 1: onBegin()
        case 2: onChange(progress)
        case 4, 8: onEnd()
        default: break
        }
    }

    private static func field(_ raw: UInt32) -> CGEventField {
        unsafeBitCast(raw, to: CGEventField.self)
    }

    // MARK: Log

    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Brow/swipe.log")
    private var loggedLines = 0

    func log(_ line: String) {
        guard UserDefaults.standard.object(forKey: "logSwipes") as? Bool ?? true, loggedLines < 3000 else { return }
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
