//
//  DockClick.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Pure logic behind the "Dock Click Opens Recent Window" setting: a plain
//  left click on a running app's Dock icon raises only that app's most
//  recently used window — exactly what confirming in the switcher does —
//  instead of the Dock's default of bringing every window of the app
//  forward. Three pieces, all AppKit-free and unit-tested:
//
//  - DockClickSetting: the UserDefaults toggle (on by default — the Dock
//    and the switcher then agree on what a click on an app does).
//  - DockClickPolicy: which clicks are ours (plain, unmodified) and which
//    window a click on a given Dock item should raise, or nil to leave the
//    click to the Dock (app not running, no windows we know of, already
//    frontmost so "minimize on click" keeps working, not an app item).
//  - DockClickGesture: the press → release state machine. The mouseDown is
//    swallowed before the Dock sees it and held with everything that follows
//    while the Dock's Accessibility tree is hit-tested off the main thread;
//    a quick release on an intercepted item raises the window, anything
//    else — hold (Dock menu), drag (drop onto an icon), a negative hit test,
//    a slow Dock — replays the held events to the Dock untouched.
//
//  DockClickInterceptor (app target) owns the event tap and turns these
//  outcomes into CGEvent swallowing, replaying and window activation.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import Foundation

// MARK: - DockClickSetting

enum DockClickSetting {

    /// UserDefaults key for the toggle (Bool).
    static let defaultsKey = "DockClickMostRecentWindow"
    /// On by default: a Dock click and the switcher agree on what selecting
    /// an app does. The status menu turns it off in one click.
    static let defaultEnabled = true

    /// Resolves the stored toggle; nil (never set) means `defaultEnabled`.
    static func resolve(_ stored: Bool?) -> Bool {
        stored ?? defaultEnabled
    }
}

// MARK: - DockClickPolicy

enum DockClickPolicy {

    /// Only an unmodified left click is ours. Command (reveal in Finder),
    /// Option (hide others), Control (context menu) and Shift clicks keep
    /// their Dock meaning, as do clicks that start with any modifier at all.
    static func isPlainClick(commandDown: Bool, optionDown: Bool, controlDown: Bool, shiftDown: Bool) -> Bool {
        !(commandDown || optionDown || controlDown || shiftDown)
    }

    /// The running app behind a Dock item: matched by bundle path first
    /// (exact), then by the item's title against the app name — the same
    /// rule `DockBadges.match` uses in the other direction.
    static func pid(for item: DockBadges.Item, in apps: [DockBadges.App]) -> pid_t? {
        if let path = item.bundlePath, let app = apps.first(where: { $0.bundlePath == path }) {
            return app.pid
        }
        return apps.first { $0.name == item.title && !item.title.isEmpty }?.pid
    }

    /// The window a plain click on `item` should raise, or nil to let the Dock
    /// handle the click. `windows` is the MRU-ordered list (most recent
    /// first), so the first window of the matched app is its most recent one.
    /// Nil when the item is not a running app we know windows for, or when the
    /// app is already frontmost — the Dock then does nothing or minimizes
    /// (the "Minimize windows on application icon click" Dock setting), and
    /// both must keep working.
    static func windowToRaise<W>(item: DockBadges.Item?, apps: [DockBadges.App], frontmostPID: pid_t?,
                                 windows: [W], ownerPID: (W) -> pid_t) -> W? {
        guard let item = item, let pid = pid(for: item, in: apps) else { return nil }
        guard pid != frontmostPID else { return nil }
        return windows.first { ownerPID($0) == pid }
    }

    /// Fallback Dock hit region when the event carries no window under the
    /// pointer: the strip of a screen's frame that its visible frame leaves
    /// out, minus the menu bar. `point` is in global top-left (CGEvent)
    /// coordinates; `mainScreenHeight` converts it into AppKit's bottom-left
    /// space the screen frames are given in. Autohidden Docks have no strip
    /// and are not detected this way.
    static func pointInDockStrip(_ point: CGPoint, mainScreenHeight: CGFloat,
                                 screens: [(frame: CGRect, visibleFrame: CGRect)]) -> Bool {
        let flipped = CGPoint(x: point.x, y: mainScreenHeight - point.y)
        for screen in screens where screen.frame.contains(flipped) {
            if screen.visibleFrame.contains(flipped) { return false }
            // Above the visible area is the menu bar (or notch), not the Dock.
            return flipped.y <= screen.visibleFrame.maxY
        }
        return false
    }
}

// MARK: - DockClickGesture

/// Press → release state machine for one intercepted Dock click. Fed the
/// mouse events that arrive while a click is pending plus the two
/// asynchronous signals (hit-test decision, hold timeout) and answers how the
/// interceptor must treat each: swallow and hold the event, replay everything
/// held to the Dock, or raise the window.
struct DockClickGesture: Equatable {

    /// Held this long without release, the press is the Dock's (its
    /// press-and-hold menu) — replay it. Also the patience for a slow Dock hit
    /// test: past it a released click degrades to the Dock's own behaviour.
    static let holdThreshold: TimeInterval = 0.3
    /// Moved this far, the press is a drag (drop onto an icon) — replay it.
    static let dragThreshold: CGFloat = 4

    enum Event: Equatable {
        case mouseDown(CGPoint, TimeInterval)
        case mouseDragged(CGPoint, TimeInterval)
        case mouseUp(CGPoint, TimeInterval)
        /// Hit test finished: true when the item resolves to a window to raise.
        case decided(intercept: Bool)
        /// The hold timer armed for gesture `id` fired.
        case holdTimeout(id: Int)
    }

    struct Outcome: Equatable {
        /// Swallow the triggering event (and hold it, unless `replay` or
        /// `activate` consumes the held events in the same step).
        var swallow = false
        /// Post every held event (including this one when swallowed) to the
        /// Dock, in order, and forget them.
        var replay = false
        /// Raise the resolved window and drop the held events.
        var activate = false
        /// Schedule `.holdTimeout(id:)` after `holdThreshold`.
        var armHoldTimer: Int?

        static let passThrough = Outcome()
    }

    private(set) var isPending = false
    /// Incremented per press so a stale hold timer is ignored.
    private(set) var id = 0
    private var origin = CGPoint.zero
    private var upSeen = false
    /// nil while the hit test is in flight.
    private var intercept: Bool?

    mutating func handle(_ event: Event) -> Outcome {
        switch event {
        case .mouseDown(let point, _):
            // A second press while one is pending: give the Dock the old one,
            // let this one pass — it can't be a clean click any more.
            if isPending {
                reset()
                return Outcome(swallow: false, replay: true)
            }
            id += 1
            isPending = true
            origin = point
            upSeen = false
            intercept = nil
            return Outcome(swallow: true, armHoldTimer: id)

        case .mouseDragged(let point, _):
            guard isPending else { return .passThrough }
            if hypot(point.x - origin.x, point.y - origin.y) > Self.dragThreshold {
                reset()
                return Outcome(swallow: true, replay: true)
            }
            return Outcome(swallow: true)

        case .mouseUp:
            guard isPending else { return .passThrough }
            if intercept == true {
                reset()
                return Outcome(swallow: true, activate: true)
            }
            // Hit test still in flight: hold the release until it lands (or
            // the hold timer gives the click back to the Dock).
            upSeen = true
            return Outcome(swallow: true)

        case .decided(let intercept):
            guard isPending else { return .passThrough }
            guard intercept else {
                reset()
                return Outcome(replay: true)
            }
            if upSeen {
                reset()
                return Outcome(activate: true)
            }
            self.intercept = true
            return .passThrough

        case .holdTimeout(let id):
            guard isPending, id == self.id else { return .passThrough }
            reset()
            return Outcome(replay: true)
        }
    }

    private mutating func reset() {
        isPending = false
        upSeen = false
        intercept = nil
    }
}
