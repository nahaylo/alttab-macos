//
//  MRUOrder.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Pure MRU (most recently used) ordering of window IDs, extracted from
//  WindowModel so it is unit-testable without AppKit or Accessibility.
//  Front of the order = most recently used. Sorting builds a rank
//  dictionary once (O(n log n) total) instead of calling firstIndex(of:)
//  inside the comparator (O(n² log n)), and uses the input index as a
//  tiebreaker because Swift's sort is not guaranteed stable. Apps are ranked
//  alongside windows so a window whose ID changes keeps its app's place.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import CoreGraphics

struct MRUOrder {

    /// MRU-ordered window IDs. Front of array = most recently used.
    private(set) var order: [CGWindowID] = []
    /// MRU-ordered apps. An app keeps its place here while it has no window in
    /// `order` — a window ID can change (a Terminal tab moved to a new
    /// window) or miss one gather (another Space, a rebuild), and without an
    /// app-level memory its replacement would be appended at the tail, taking
    /// the app from "previous" to "last" in the switcher.
    private(set) var appOrder: [pid_t] = []
    /// Owner of each ranked window, learned from seeds, promotions and syncs.
    private var owner: [CGWindowID: pid_t] = [:]

    /// Replaces the order wholesale (seeding from the window stacking order).
    mutating func seed(_ ids: [CGWindowID]) {
        order = ids
        owner = [:]
        appOrder = []
    }

    /// Seeds windows and, from their first occurrences, the app order.
    mutating func seed(windows: [(id: CGWindowID, pid: pid_t)]) {
        order = windows.map { $0.id }
        owner = Dictionary(windows.map { ($0.id, $0.pid) }, uniquingKeysWith: { first, _ in first })
        appOrder = []
        for window in windows where !appOrder.contains(window.pid) {
            appOrder.append(window.pid)
        }
    }

    /// Moves a window to the front (most recently used), and its app with it.
    /// `pid` may be omitted when the window's owner is already known.
    mutating func promoteToFront(_ id: CGWindowID, pid: pid_t? = nil) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        guard let pid = pid ?? owner[id] else { return }
        owner[id] = pid
        appOrder.removeAll { $0 == pid }
        appOrder.insert(pid, at: 0)
    }

    /// Drops IDs that no longer exist and appends newly discovered ones at the
    /// end, preserving their relative order. Owner-less variant: prefer
    /// `sync(windows:)`, which keeps an app's rank across ID changes.
    mutating func sync(with validIDs: [CGWindowID]) {
        let valid = Set(validIDs)
        order.removeAll { !valid.contains($0) }
        owner = owner.filter { valid.contains($0.key) }
        let known = Set(order)
        for id in validIDs where !known.contains(id) {
            order.append(id)
        }
    }

    /// Drops windows that no longer exist and ranks newly discovered ones by
    /// their app: a new window of a ranked app goes after that app's existing
    /// windows and before the first window of any app used less recently —
    /// so a replaced or briefly missing window returns to its app's place,
    /// not the tail. Windows of apps never seen before go to the tail, in
    /// input order, and their apps join the app order last.
    mutating func sync(windows: [(id: CGWindowID, pid: pid_t)]) {
        let valid = Set(windows.map { $0.id })
        order.removeAll { !valid.contains($0) }
        owner = owner.filter { valid.contains($0.key) }
        for window in windows { owner[window.id] = window.pid }

        var appRank = Dictionary(appOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var known = Set(order)
        for window in windows where !known.contains(window.id) {
            known.insert(window.id)
            guard let rank = appRank[window.pid] else {
                appRank[window.pid] = appOrder.count
                appOrder.append(window.pid)
                order.append(window.id)
                continue
            }
            // Owner-less entries (from an owner-less seed) rank as least recent.
            let index = order.firstIndex { id in
                guard let pid = owner[id], let other = appRank[pid] else { return true }
                return other > rank
            } ?? order.count
            order.insert(window.id, at: index)
        }
    }

    /// Forgets a terminated app, so a reused pid starts unranked.
    mutating func forgetApp(_ pid: pid_t) {
        appOrder.removeAll { $0 == pid }
    }

    /// Returns the items sorted by MRU rank. IDs not present in the order sort
    /// last, keeping their relative input order.
    func sorted<T>(_ items: [T], id: (T) -> CGWindowID) -> [T] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) },
                              uniquingKeysWith: { first, _ in first })
        return items.enumerated()
            .sorted { a, b in
                let rankA = rank[id(a.element)] ?? Int.max
                let rankB = rank[id(b.element)] ?? Int.max
                return rankA == rankB ? a.offset < b.offset : rankA < rankB
            }
            .map { $0.element }
    }
}
