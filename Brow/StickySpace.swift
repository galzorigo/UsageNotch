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

/// Whether you're currently in a full screen app's Space. There the whole menu bar strip is
/// solid black, so the open pill should curve into the bottom of that strip, not the top of the screen.
enum SpaceInfo {
    static var isFullScreen: Bool {
        let connection = _CGSDefaultConnection()
        return CGSSpaceGetType(connection, CGSGetActiveSpace(connection)) == 4 // 4 = full screen
    }

    /// The Space you're in now.
    static var activeID: UInt64 { CGSGetActiveSpace(_CGSDefaultConnection()) }

    /// The Spaces on the active display, in order from left to right (as in Mission Control).
    static func orderedIDs() -> [UInt64] {
        let active = activeID
        guard let displays = CGSCopyManagedDisplaySpaces(_CGSDefaultConnection()) as? [[String: Any]] else { return [] }
        for display in displays {
            let ids = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space in
                (space["id64"] as? NSNumber)?.uint64Value ?? (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
            }
            if ids.contains(active) { return ids }
        }
        return []
    }

    /// The Spaces either side of `space` (the current one by default), if there are any.
    static func neighbours(of space: UInt64 = activeID) -> (left: UInt64?, right: UInt64?) {
        let ids = orderedIDs()
        guard let index = ids.firstIndex(of: space) else { return (nil, nil) }
        return (index > 0 ? ids[index - 1] : nil, index + 1 < ids.count ? ids[index + 1] : nil)
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

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSSpaceGetType")
private func CGSSpaceGetType(_ cid: CGSConnectionID, _ space: CGSSpaceID) -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray
