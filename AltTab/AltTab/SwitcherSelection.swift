//
//  SwitcherSelection.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Pure selection state for one switcher session, extracted from AppDelegate
//  so the trickiest ordering behavior — which slot the first Tab lands on —
//  is unit-testable without AppKit. The displayed list is served from a cache
//  that can be stale (windows opened or closed since the last gather), so the
//  initial anchor cannot assume slot 0 is the currently focused window:
//  activate() verifies that assumption against the actual focused window ID
//  and anchors at slot 0 when it fails (the list head is then the true
//  previous window). reconcile() applies the fresh gather mid-session:
//  before the user has cycled, the selection is re-anchored against the
//  corrected list; after a manual cycle (or click) it follows the selected
//  window ID, because the user is visually tracking that window.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import CoreGraphics

struct SwitcherSelection {

    /// Window IDs currently displayed, in MRU order (front = most recent).
    private(set) var windowIDs: [CGWindowID] = []

    /// Index of the highlighted slot.
    private(set) var selectedIndex: Int = 0

    /// True once the user has expressed intent (Tab/arrow cycle or click);
    /// reconcile() then follows the selected window instead of re-anchoring.
    private(set) var hasCycled: Bool = false

    /// True when the session opened with Option+Shift+Tab: the anchor sits at
    /// the list tail, and reconcile() re-anchors with the same direction.
    private(set) var reverse: Bool = false

    /// ID of the highlighted window, if any.
    var selectedID: CGWindowID? {
        windowIDs.indices.contains(selectedIndex) ? windowIDs[selectedIndex] : nil
    }

    /// Candidate order for confirming: the selected slot first, then the rest
    /// falling through in the session's cycle direction, wrapping. Confirm
    /// walks this order past ghost windows — entries closed since the last
    /// gather. Forward sessions fall through in displayed (MRU) order; reverse
    /// sessions fall through backward, so a ghost at the LRU tail retries the
    /// next-least-recent window instead of snapping to the focused head.
    var confirmationOrder: [CGWindowID] {
        guard windowIDs.indices.contains(selectedIndex) else { return windowIDs }
        if reverse {
            return Array(windowIDs[...selectedIndex].reversed()) + Array(windowIDs[(selectedIndex + 1)...].reversed())
        }
        return Array(windowIDs[selectedIndex...]) + Array(windowIDs[..<selectedIndex])
    }

    /// The slot the first Tab press should land on. Forward: slot 1 ("previous
    /// window") is only correct when slot 0 really is the focused window; when
    /// the focused window is missing from the list (created after the last
    /// gather) or ranked elsewhere, slot 0 holds the true previous window. An
    /// unknown focus keeps the classic slot-1 default. Reverse (Option+Shift+
    /// Tab): one step back from the current window wraps to the least-recently
    /// -used end — the tail — stepping one further in when the tail IS the
    /// focused window (selecting it would be a no-op switch).
    static func initialIndex(windowIDs: [CGWindowID], focusedWindowID: CGWindowID?, reverse: Bool = false) -> Int {
        guard windowIDs.count > 1 else { return 0 }
        if reverse {
            let last = windowIDs.count - 1
            if let focused = focusedWindowID, windowIDs[last] == focused { return last - 1 }
            return last
        }
        guard let focused = focusedWindowID else { return 1 }
        return windowIDs[0] == focused ? 1 : 0
    }

    /// Starts a session: anchors the selection against the actual focused window.
    mutating func activate(windowIDs: [CGWindowID], focusedWindowID: CGWindowID?, reverse: Bool = false) {
        self.windowIDs = windowIDs
        self.reverse = reverse
        hasCycled = false
        selectedIndex = Self.initialIndex(windowIDs: windowIDs, focusedWindowID: focusedWindowID, reverse: reverse)
    }

    mutating func cycleNext() {
        guard !windowIDs.isEmpty else { return }
        hasCycled = true
        selectedIndex = (selectedIndex + 1) % windowIDs.count
    }

    mutating func cyclePrevious() {
        guard !windowIDs.isEmpty else { return }
        hasCycled = true
        selectedIndex = (selectedIndex - 1 + windowIDs.count) % windowIDs.count
    }

    /// Explicit pick (thumbnail click) — counts as user intent like a cycle.
    mutating func select(index: Int) {
        guard windowIDs.indices.contains(index) else { return }
        hasCycled = true
        selectedIndex = index
    }

    /// Applies a freshly gathered list mid-session. Follows the selected
    /// window ID only after the user has cycled; otherwise re-anchors, so a
    /// stale initial default cannot survive the arrival of correct data.
    mutating func reconcile(windowIDs fresh: [CGWindowID], focusedWindowID: CGWindowID?) {
        let previousID = selectedID
        let previousIndex = selectedIndex
        windowIDs = fresh
        guard !fresh.isEmpty else {
            selectedIndex = 0
            return
        }
        if hasCycled {
            if let id = previousID, let index = fresh.firstIndex(of: id) {
                selectedIndex = index
            } else {
                selectedIndex = min(previousIndex, fresh.count - 1)
            }
        } else {
            selectedIndex = Self.initialIndex(windowIDs: fresh, focusedWindowID: focusedWindowID, reverse: reverse)
        }
    }
}
