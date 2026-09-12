//
//  WindowActivator.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Handles the actual window switching: unminimizes if needed, activates the
//  owning application, and raises the specific window via AXUIElement. Window
//  matching uses CGWindowID first (via _AXUIElementGetWindow), falling back
//  to exact-title matching. When neither matches, only the app activation
//  stands — deliberately no raise-first-window fallback, which could surface
//  an arbitrary window the user never selected.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  Version: 1.1.0
//  Date:    2026-03-17
//  License: MIT
//

import Cocoa
import ApplicationServices

enum WindowActivator {

    /// Serial queue for the synchronous Accessibility IPC involved in raising a window.
    /// Kept off the main thread so a slow/busy target app can't freeze the switcher on
    /// confirm — profiled via `sample` as ~75% of main-thread activation cost, dominated
    /// by AXUIElementCopyAttributeValue(kAXWindows) blocking in mach_msg. Client-side AX
    /// queries against other apps are safe off-main; each call is additionally bounded by
    /// a messaging timeout (see below).
    private static let axQueue = DispatchQueue(label: "com.alttab.window-activator", qos: .userInitiated)

    /// Upper bound (seconds) on a single AX message. Long enough for a legitimately busy
    /// app to answer, short enough that a wedged app can't tie up the queue indefinitely.
    private static let axMessagingTimeout: Float = 1.0

    /// Returns which of the given windows still exist in the window server —
    /// one batched WindowServer query, no AX IPC. Used at confirm time to skip
    /// ghost entries (windows closed since the last gather) before activating.
    /// Minimized and other-Space windows still exist and pass the check.
    /// CGWindowListCreateDescriptionFromArray expects the IDs stored directly
    /// as pointer-sized CFArray values (NULL callbacks) — bridging [CGWindowID]
    /// `as CFArray` yields CFNumbers and silently matches nothing. Fails open
    /// (all live) if the query itself fails, so confirm can still switch.
    static func liveWindowIDs(_ ids: [CGWindowID]) -> Set<CGWindowID> {
        guard !ids.isEmpty else { return [] }
        var values: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let idArray = CFArrayCreate(kCFAllocatorDefault, &values, values.count, nil),
              let descriptions = CGWindowListCreateDescriptionFromArray(idArray) as? [[String: Any]] else {
            return Set(ids)
        }
        return Set(descriptions.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    /// Activates the given window: brings the owning app forward on the main thread, then
    /// unminimizes (if needed) and raises the specific window via AXUIElement off the main
    /// thread so confirm returns immediately and the UI never blocks.
    static func activate(window: WindowInfo) {
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else { return }

        // Bring the owning app forward on the main thread — this is an AppKit call and is
        // cheap (~1% of activation cost); AppKit is not safe to touch off the main thread.
        // activateIgnoringOtherApps is deprecated on macOS 14+, where plain activate()
        // has the same effect for a user-initiated switch.
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        // The expensive part — synchronous AX IPC to fetch the app's window list and raise
        // the target — runs off the main thread.
        axQueue.async {
            if window.isMinimized {
                unminimize(window: window)
            }
            raiseWindow(window: window)
        }
    }

    // MARK: - Unminimize

    private static func unminimize(window: WindowInfo) {
        let axApp = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(axApp, axMessagingTimeout)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }

        for axWindow in axWindows {
            // Timeouts are per-element: without this, the setter below waits
            // on the ~6s AX default against a wedged app (the app-element
            // timeout above does not carry over).
            AXUIElementSetMessagingTimeout(axWindow, axMessagingTimeout)
            var windowID: CGWindowID = 0
            _ = _AXUIElementGetWindow(axWindow, &windowID)

            if windowID == window.windowID {
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                break
            }
        }
    }

    // MARK: - Raise Window

    private static func raiseWindow(window: WindowInfo) {
        let axApp = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(axApp, axMessagingTimeout)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }

        // Try to match by CGWindowID first
        for axWindow in axWindows {
            // Per-element timeout: covers the raise/main/title calls below on
            // these same elements (the fallback loop reuses this array).
            AXUIElementSetMessagingTimeout(axWindow, axMessagingTimeout)
            var windowID: CGWindowID = 0
            _ = _AXUIElementGetWindow(axWindow, &windowID)

            if windowID == window.windowID {
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, true as CFTypeRef)
                return
            }
        }

        // Fallback: match by title + approximate bounds
        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String ?? ""

            if title == window.windowTitle && !title.isEmpty {
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, true as CFTypeRef)
                return
            }
        }

        // No match: leave the app activation as the failure mode. Raising an
        // arbitrary window here (the old last resort) surfaced windows the
        // user never picked when a stale/ghost entry was confirmed.
    }
}
