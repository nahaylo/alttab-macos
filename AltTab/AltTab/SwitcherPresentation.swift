//
//  SwitcherPresentation.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Pure presentation policy for the switcher list, extracted so it is
//  unit-testable without AppKit:
//
//  - SwitcherStyle: "Icons" (the native Cmd-Tab look — one large app icon per
//    item, filled selection highlight, and one caption that floats under the
//    selected icon at panel level so it is never truncated to the cell width)
//    or "Thumbnails" (the original cell with preview/icon + title + app name).
//    Owns the cell metrics so the panel and cell agree on geometry; Icons
//    metrics adapt to the item count like the native switcher — icons shrink
//    so the whole row fits the available width, down to a floor, and only
//    past that does the strip scroll.
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

    /// Largest icon edge for Icons style (what the native switcher draws for
    /// a handful of apps) and the floor it shrinks to before scrolling.
    static let maxIconSize: CGFloat = 128
    static let minIconSize: CGFloat = 48
    /// Native proportions, all relative to the icon edge (measured off the
    /// Dock's switcher): the selection highlight is a fifth larger than the
    /// icon, highlights sit a tenth of an icon apart, and the panel's side
    /// padding is a fifth of an icon beyond the outer highlights.
    static let highlightScale: CGFloat = 1.2
    static let gapScale: CGFloat = 0.1
    static let sidePaddingScale: CGFloat = 0.2
    /// Breathing room between the highlight and the cell edge, per side.
    static let highlightInset: CGFloat = 0
    /// Vertical panel padding above the highlights and below the caption.
    static let iconsPanelPaddingY: CGFloat = 8

    /// Fraction of the screen width the panel may occupy. The native switcher
    /// runs nearly edge to edge, which is how it keeps icons large with many
    /// apps open; the Thumbnails strip keeps its historical 85%.
    var maxPanelWidthFraction: CGFloat {
        switch self {
        case .thumbnails: return 0.85
        case .icons: return 0.95
        }
    }

    /// Cell geometry for `count` items in a panel at most `maxPanelWidth`
    /// wide. Thumbnails cells are fixed. Icons cells size their icon so the
    /// whole row — cells, gaps and side padding — fits, clamped to
    /// [minIconSize, maxIconSize]; a row that does not fit even at the floor
    /// scrolls (the panel's existing behavior).
    func metrics(count: Int, maxPanelWidth: CGFloat) -> CellMetrics {
        switch self {
        case .thumbnails:
            return CellMetrics(iconSize: 0, highlightSize: 0, itemWidth: 180, itemHeight: 160, itemSpacing: 12,
                               panelPaddingX: 20, panelPaddingY: 20, panelCornerRadius: 16)
        case .icons:
            let n = CGFloat(max(1, count))
            // Width in terms of the icon edge i:
            //   n * (highlightScale*i + 2*inset) + (n-1) * gapScale*i + 2 * sidePaddingScale*i <= maxPanelWidth
            let perIcon = Self.highlightScale * n + Self.gapScale * (n - 1) + 2 * Self.sidePaddingScale
            let fitted = ((maxPanelWidth - 2 * Self.highlightInset * n) / perIcon).rounded(.down)
            let icon = min(Self.maxIconSize, max(Self.minIconSize, fitted))
            let highlight = (icon * Self.highlightScale).rounded()
            let gap = (icon * Self.gapScale).rounded()
            let sidePadding = (icon * Self.sidePaddingScale).rounded()
            let side = highlight + 2 * Self.highlightInset
            return CellMetrics(iconSize: icon, highlightSize: highlight, itemWidth: side, itemHeight: side,
                               itemSpacing: gap, panelPaddingX: sidePadding, panelPaddingY: Self.iconsPanelPaddingY,
                               panelCornerRadius: 28)
        }
    }

    /// Height of the caption row the panel reserves below the strip. Icons
    /// style draws the selected item's caption there (full width, no cell
    /// clipping — the native switcher does the same); Thumbnails puts its
    /// labels inside the cell and needs none.
    var captionRowHeight: CGFloat {
        switch self {
        case .thumbnails: return 0
        case .icons: return 20
        }
    }

    /// The caption for a selected Icons-style item. Grouped lists are apps,
    /// so the app name (as the system switcher shows); otherwise the window
    /// title, falling back to the app name for untitled windows.
    static func caption(windowTitle: String, appName: String, grouped: Bool) -> String {
        if grouped || windowTitle.isEmpty { return appName }
        return windowTitle
    }

}

// MARK: - CellMetrics

/// Geometry of one strip cell, shared by the panel (strip sizing) and the
/// cell view so they cannot disagree.
struct CellMetrics: Equatable {
    /// Icon edge (Icons style); 0 for Thumbnails, whose image area is derived
    /// from the cell height instead.
    let iconSize: CGFloat
    /// Edge of the rounded selection highlight behind the icon (Icons style).
    let highlightSize: CGFloat
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let itemSpacing: CGFloat
    /// Panel padding around the strip (and caption row), per side.
    let panelPaddingX: CGFloat
    let panelPaddingY: CGFloat
    let panelCornerRadius: CGFloat

    /// Total strip width for `count` cells.
    func stripWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * itemWidth + CGFloat(count - 1) * itemSpacing
    }

    /// Panel width that shows `count` cells without scrolling.
    func panelWidth(count: Int) -> CGFloat {
        stripWidth(count: count) + 2 * panelPaddingX
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
