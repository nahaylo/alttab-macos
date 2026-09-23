//
//  DockClickInterceptor.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Makes a plain click on a running app's Dock icon raise only that app's
//  most recent window (like confirming in the switcher) instead of all of
//  them. A second, mouse-only CGEvent tap — installed only while the setting
//  is on, so no mouse traffic flows through AltTab otherwise — swallows a
//  left mouseDown that lands on a Dock window, hit-tests the Dock's
//  Accessibility tree off the main thread to find the item under the pointer,
//  and resolves it through `resolveWindow` (policy + window cache, main
//  thread). A quick release then activates that window; a hold, a drag, a
//  modifier, a non-app item, an app without known windows or the frontmost
//  app hand the click back to the Dock by re-posting the held events, tagged
//  so this tap lets them through. The pure `DockClickGesture` decides.
//
//  The tap sits at the annotated session point, where the WindowServer has
//  stamped each event with the window under the pointer, so "is this the
//  Dock?" is one cheap window-list query — never AX IPC on the tap thread.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import Cocoa

final class DockClickInterceptor {

    /// Main thread. The window to raise for the Dock item under the click,
    /// or nil to leave the click to the Dock (see `DockClickPolicy`).
    var resolveWindow: ((DockBadges.Item?) -> WindowInfo?)?
    /// Main thread. Raise the resolved window.
    var onActivate: ((WindowInfo) -> Void)?

    private let dockReader: DockBadgeReader
    private var gesture = DockClickGesture()
    /// Swallowed events of the pending press, in arrival order.
    private var held: [CGEvent] = []
    private var pendingWindow: WindowInfo?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var reEnableTimer: Timer?
    private var dockPID: pid_t?

    /// Stamped into `eventSourceUserData` on replayed events so the tap
    /// recognises its own posts and passes them through.
    private static let replayTag: Int64 = 0x414C_5454_444B // "ALTTDK"
    private static let dockBundleID = "com.apple.dock"

    init(dockReader: DockBadgeReader) {
        self.dockReader = dockReader
    }

    // MARK: - Lifecycle (main thread)

    var isRunning: Bool { eventTap != nil }

    /// Installs the tap; a no-op when already running. Needs Accessibility.
    func start() {
        guard eventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                                (1 << CGEventType.leftMouseUp.rawValue) |
                                (1 << CGEventType.leftMouseDragged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dockClickEventCallback,
            userInfo: userInfo
        ) else {
            NSLog("AltTab: Failed to create the Dock click event tap. Is Accessibility enabled?")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        reEnableTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, let tap = self.eventTap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            NSLog("AltTab: Dock click tap was disabled by system, re-enabling.")
            CGEvent.tapEnable(tap: tap, enable: true)
            self.giveBackPending()
        }
        reEnableTimer?.tolerance = 0.5
        NSLog("AltTab: Dock click tap installed")
    }

    func stop() {
        reEnableTimer?.invalidate()
        reEnableTimer = nil
        giveBackPending()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
    }

    // MARK: - Event handling (tap thread = main)

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            giveBackPending()
            return Unmanaged.passUnretained(event)
        }
        // Our own replayed events come back through the tap: let them through.
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayTag {
            return Unmanaged.passUnretained(event)
        }

        let point = event.location
        let now = event.timestamp.seconds
        switch type {
        case .leftMouseDown:
            if !gesture.isPending {
                guard DockClickPolicy.isPlainClick(commandDown: event.flags.contains(.maskCommand),
                                                   optionDown: event.flags.contains(.maskAlternate),
                                                   controlDown: event.flags.contains(.maskControl),
                                                   shiftDown: event.flags.contains(.maskShift)),
                      isOnDock(event) else {
                    return Unmanaged.passUnretained(event)
                }
            }
            let outcome = gesture.handle(.mouseDown(point, now))
            let result = apply(outcome, to: event)
            if outcome.armHoldTimer != nil { hitTest(at: point, gestureID: gesture.id) }
            return result

        case .leftMouseDragged:
            guard gesture.isPending else { return Unmanaged.passUnretained(event) }
            return apply(gesture.handle(.mouseDragged(point, now)), to: event)

        case .leftMouseUp:
            guard gesture.isPending else { return Unmanaged.passUnretained(event) }
            return apply(gesture.handle(.mouseUp(point, now)), to: event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Carries out a gesture outcome. `event` is the triggering event, nil for
    /// the asynchronous signals (decision, hold timeout).
    @discardableResult
    private func apply(_ outcome: DockClickGesture.Outcome, to event: CGEvent?) -> Unmanaged<CGEvent>? {
        if outcome.swallow, let event = event, let copy = event.copy() {
            held.append(copy)
        }
        if let id = outcome.armHoldTimer {
            DispatchQueue.main.asyncAfter(deadline: .now() + DockClickGesture.holdThreshold) { [weak self] in
                guard let self = self else { return }
                self.apply(self.gesture.handle(.holdTimeout(id: id)), to: nil)
            }
        }
        if outcome.replay {
            replayHeld()
        }
        if outcome.activate {
            held.removeAll()
            if let window = pendingWindow {
                onActivate?(window)
            }
        }
        if !gesture.isPending {
            pendingWindow = nil
        }
        guard let event = event else { return nil }
        return outcome.swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Posts the held events back into the HID stream, in order, tagged so
    /// this tap passes them; the Dock then sees the press it was denied.
    private func replayHeld() {
        for event in held {
            event.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
            event.post(tap: .cghidEventTap)
        }
        held.removeAll()
    }

    /// Ends a pending press by handing it to the Dock — used when the tap is
    /// torn down or was disabled mid-gesture and the release may be lost.
    private func giveBackPending() {
        guard gesture.isPending else { return }
        apply(gesture.handle(.holdTimeout(id: gesture.id)), to: nil)
    }

    // MARK: - Dock detection

    /// Whether the press landed on a window owned by the Dock — the
    /// WindowServer's window-under-pointer stamp resolved through one
    /// window-list query. Falls back to the screen strip the Dock reserves
    /// when the stamp is missing.
    private func isOnDock(_ event: CGEvent) -> Bool {
        guard let dockPID = currentDockPID() else { return false }
        let windowID = CGWindowID(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        if windowID != 0,
           let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
           let owner = info[kCGWindowOwnerPID as String] as? pid_t {
            return owner == dockPID
        }
        guard let main = NSScreen.main else { return false }
        return DockClickPolicy.pointInDockStrip(event.location, mainScreenHeight: main.frame.height,
                                                screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) })
    }

    private func currentDockPID() -> pid_t? {
        if let pid = dockPID, NSRunningApplication(processIdentifier: pid)?.isTerminated == false {
            return pid
        }
        dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first?.processIdentifier
        return dockPID
    }

    // MARK: - Hit test

    private func hitTest(at point: CGPoint, gestureID: Int) {
        dockReader.item(at: point) { [weak self] item in
            guard let self = self, self.gesture.isPending, self.gesture.id == gestureID else { return }
            let window = self.resolveWindow?(item)
            self.pendingWindow = window
            self.apply(self.gesture.handle(.decided(intercept: window != nil)), to: nil)
        }
    }
}

// MARK: - C Callback Bridge

private func dockClickEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let interceptor = Unmanaged<DockClickInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    return interceptor.handleEvent(type: type, event: event)
}

private extension CGEventTimestamp {
    /// Mach absolute time in nanoseconds → seconds.
    var seconds: TimeInterval { TimeInterval(self) / 1_000_000_000 }
}
