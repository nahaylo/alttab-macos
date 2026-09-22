//
//  SwitcherPresentation.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Pure presentation policy for the switcher list, extracted so it is
//  unit-testable without AppKit:
//
//  - SwitcherStyle: "Icons" (the native Cmd-Tab look — one large app icon per
//    item, filled selection highlight, a single title under the selected item)
//    or "Thumbnails" (the original cell with preview/icon + title + app name).
//    Owns the cell metrics so the panel and cell agree on geometry.
//  - AppGrouping: "Group by Application" collapses the MRU-sorted window list
//    to one representative window per app — the first (most recent) one — so
//    the list reads as apps ordered by their latest use, exactly what the
//    system app switcher shows. Confirming a group activates that window.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import CoreGraphics
import Darwin

// MARK: - SwitcherStyle

enum SwitcherStyle: String, CaseIterable {
    case thumbnails
    case icons

    /// The original look ships as the default.
    static let defaultStyle: SwitcherStyle = .thumbnails
    /// UserDefaults key. Absent (or unknown) means `defaultStyle`.
    static let defaultsKey = "SwitcherStyle"

    static func resolve(_ raw: String?) -> SwitcherStyle {
        raw.flatMap(SwitcherStyle.init(rawValue:)) ?? defaultStyle
    }

    /// Menu label.
    var title: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .icons: return "Icons"
        }
    }

    /// Window previews (ScreenCaptureKit) only make sense where a cell has a
    /// preview area. Icons style never captures, so it never touches Screen
    /// Recording either — the "Show Window Previews" item is disabled for it.
    var showsPreviews: Bool {
        self == .thumbnails
    }

    /// Cell geometry, shared by the panel (strip sizing) and the cell view.
    var itemWidth: CGFloat {
        switch self {
        case .thumbnails: return 180
        case .icons: return 120
        }
    }

    var itemHeight: CGFloat {
        switch self {
        case .thumbnails: return 160
        case .icons: return 140
        }
    }

    var itemSpacing: CGFloat {
        switch self {
        case .thumbnails: return 12
        case .icons: return 8
        }
    }

    /// Icon edge for Icons style (the native switcher draws roughly this size).
    var iconSize: CGFloat {
        switch self {
        case .thumbnails: return 0
        case .icons: return 96
        }
    }
}

// MARK: - AppGrouping

enum AppGrouping {

    /// UserDefaults key for the "Group by Application" toggle (Bool, default off).
    static let defaultsKey = "GroupByApplication"

    /// Keeps the first item per owner pid, preserving order. Fed an MRU-sorted
    /// list, the survivor for each app is its most recently used window and
    /// the apps come out ordered by latest use.
    static func collapse<T>(_ items: [T], ownerPID: (T) -> pid_t) -> [T] {
        var seen = Set<pid_t>()
        return items.filter { seen.insert(ownerPID($0)).inserted }
    }

    /// The grouped list's stand-in for `windowID`: the representative of the
    /// app that owns it. Used to anchor the initial selection — the focused
    /// window may not be its app's MRU-top window (cache staleness), in which
    /// case anchoring on its raw ID would find nothing and land on slot 0,
    /// i.e. the current app, making the first Tab a no-op switch.
    static func representative<T>(of windowID: CGWindowID?, in grouped: [T], full: [T],
                                  id: (T) -> CGWindowID, ownerPID: (T) -> pid_t) -> CGWindowID? {
        guard let windowID = windowID else { return nil }
        if grouped.contains(where: { id($0) == windowID }) { return windowID }
        guard let owner = full.first(where: { id($0) == windowID }).map(ownerPID) else { return nil }
        return grouped.first(where: { ownerPID($0) == owner }).map(id)
    }
}
