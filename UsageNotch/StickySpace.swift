import AppKit

/// A private, always-visible Space that the notch panel lives in.
///
/// Normal "all Spaces" windows get hidden while macOS animates between Spaces
/// (e.g. swiping to a full-screen app). Windows in this Space sit above every
/// Space and never move, so the pill stays put during the swipe.
///
/// This uses private macOS APIs (the same trick boring.notch uses). Fine for a
/// personal app, not allowed on the App Store, and could change in a future macOS.
final class StickySpace {
    private let connection = _CGSDefaultConnection()
    private let id: CGSSpaceID

    init() {
        id = CGSSpaceCreate(connection, 0x1, nil)
        CGSSpaceSetAbsoluteLevel(connection, id, Int(Int32.max)) // above everything
        CGSShowSpaces(connection, [id] as NSArray)
    }

    func add(_ window: NSWindow) {
        CGSAddWindowsToSpaces(connection, [window.windowNumber] as NSArray, [id] as NSArray)
    }

    deinit {
        CGSHideSpaces(connection, [id] as NSArray)
        CGSSpaceDestroy(connection, id)
    }
}

// MARK: Private CoreGraphics (SkyLight) functions

private typealias CGSConnectionID = UInt
private typealias CGSSpaceID = UInt64

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> CGSConnectionID

@_silgen_name("CGSSpaceCreate")
private func CGSSpaceCreate(_ cid: CGSConnectionID, _ flag: Int, _ options: NSDictionary?) -> CGSSpaceID

@_silgen_name("CGSSpaceDestroy")
private func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)

@_silgen_name("CGSSpaceSetAbsoluteLevel")
private func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int)

@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)

@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)

@_silgen_name("CGSHideSpaces")
private func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)
