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
//  - DockBadges: matches the Dock's application items (read via Accessibility
//    by DockBadgeReader) to the switcher's apps and yields the badge text to
//    draw on each icon, as the native switcher does.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import CoreGraphics
import Darwin
import Foundation

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

    /// Largest VISIBLE icon edge for Icons style (what the native switcher
    /// draws for a handful of apps) and the floor it shrinks to before
    /// scrolling. "Visible" because macOS app icons carry a transparent
    /// margin: the artwork fills only ~80% of the image (the 824/1024 icon
    /// grid), so every proportion below is relative to the artwork and the
    /// image frame is enlarged to compensate — sizing to the frame made all
    /// the paddings come out a quarter too big.
    /// 111pt visible is the Dock switcher's ceiling as measured: with room to
    /// spare it narrows the panel rather than growing the icons further.
    static let maxIconSize: CGFloat = 111
    static let minIconSize: CGFloat = 48
    static let iconArtworkFraction: CGFloat = 0.8
    /// Native proportions, relative to the visible icon edge (measured off
    /// pixel screenshots of the Dock's switcher): the selection highlight is
    /// 15% larger than the icon, highlights sit 0.06 icon apart (icon pitch
    /// 1.21 — closer than the artwork's own transparent margin, so the cell
    /// IS the highlight and the image overhangs it into that margin), the
    /// panel edge is 0.16 icon beyond the outer highlights, and the panel top
    /// sits 0.25 icon above the icon.
    static let highlightScale: CGFloat = 1.15
    static let gapScale: CGFloat = 0.06
    static let sidePaddingScale: CGFloat = 0.16
    static let topPaddingScale: CGFloat = 0.25
    /// Below the icon: the caption label's top sits captionGapScale of an
    /// icon under the artwork (glyphs a few points lower still), and the
    /// panel ends bottomPaddingScale under the label.
    static let captionGapScale: CGFloat = 0.14
    static let bottomPaddingScale: CGFloat = 0.08
    /// Caption text height budget (13pt system font).
    static let captionTextHeight: CGFloat = 16

    /// Fraction of the screen width the panel may occupy. The native switcher
    /// spans 90% of the screen (measured), which is how it keeps icons large
    /// with many apps open; the Thumbnails strip keeps its historical 85%.
    var maxPanelWidthFraction: CGFloat {
        switch self {
        case .thumbnails: return 0.85
        case .icons: return 0.9
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
            return CellMetrics(iconSize: 0, iconFrame: 0, highlightSize: 0, itemWidth: 180, itemHeight: 160,
                               itemSpacing: 12, panelPaddingX: 20, panelPaddingY: 20, panelPaddingBottom: 20,
                               captionRowHeight: 0, panelCornerRadius: 16)
        case .icons:
            let n = CGFloat(max(1, count))
            // Everything in units of the visible icon edge v. The cell is the
            // highlight wide (so highlights can sit at the native pitch) and
            // the image frame (v / artworkFraction) tall; the image overhangs
            // the cell horizontally by (frame - highlight) / 2 per side, all
            // of it inside the artwork's transparent margin, so nothing
            // visible is ever clipped by the strip.
            let frameScale = 1 / Self.iconArtworkFraction                    // 1.25
            let perIcon = Self.highlightScale * n + Self.gapScale * (n - 1) + 2 * Self.sidePaddingScale
            // Panel top → icon top is topPaddingScale of the icon; the frame's
            // own margin above the artwork supplies part of that.
            let frameMarginScale = (frameScale - 1) / 2

            func build(_ visible: CGFloat) -> CellMetrics {
                let frame = (visible * frameScale).rounded()
                let highlight = (visible * Self.highlightScale).rounded()
                // The caption row starts at the cell's bottom edge, which is
                // already frameMargin below the artwork.
                let captionRow = max(0, (visible * (Self.captionGapScale - frameMarginScale)).rounded() + Self.captionTextHeight)
                return CellMetrics(iconSize: visible, iconFrame: frame,
                                   highlightSize: highlight,
                                   itemWidth: highlight, itemHeight: frame,
                                   itemSpacing: max(0, (visible * Self.gapScale).rounded()),
                                   panelPaddingX: max(0, (visible * Self.sidePaddingScale).rounded()),
                                   panelPaddingY: max(4, (visible * (Self.topPaddingScale - frameMarginScale)).rounded()),
                                   panelPaddingBottom: max(4, (visible * Self.bottomPaddingScale).rounded()),
                                   captionRowHeight: captionRow,
                                   panelCornerRadius: 28)
            }

            var visible = min(Self.maxIconSize, max(Self.minIconSize, (maxPanelWidth / perIcon).rounded(.down)))
            var metrics = build(visible)
            // Rounding each part up can overflow by a few points; step down
            // until the rounded panel really fits (or the floor is reached).
            while metrics.panelWidth(count: count) > maxPanelWidth && visible > Self.minIconSize {
                visible -= 1
                metrics = build(visible)
            }
            return metrics
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
    /// Visible icon artwork edge (Icons style); 0 for Thumbnails, whose image
    /// area is derived from the cell height instead.
    let iconSize: CGFloat
    /// Edge of the image view that renders the icon — larger than `iconSize`
    /// by the artwork's built-in transparent margin.
    let iconFrame: CGFloat
    /// Edge of the rounded selection highlight behind the icon (Icons style).
    let highlightSize: CGFloat
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let itemSpacing: CGFloat
    /// Panel padding: sides, above the strip, and below the caption row.
    let panelPaddingX: CGFloat
    let panelPaddingY: CGFloat
    let panelPaddingBottom: CGFloat
    /// Height of the caption row the panel reserves below the strip. Icons
    /// style draws the selected item's caption there (full width, no cell
    /// clipping — the native switcher does the same); Thumbnails puts its
    /// labels inside the cell and needs none (0).
    let captionRowHeight: CGFloat
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

    /// Panel height: strip, caption row and vertical padding.
    var panelHeight: CGFloat {
        panelPaddingY + itemHeight + captionRowHeight + panelPaddingBottom
    }
}

// MARK: - DockBadges

enum DockBadges {

    /// One application item of the Dock, as read from its Accessibility tree.
    struct Item: Equatable {
        /// Bundle path from the item's AXURL (nil if the Dock gave none).
        let bundlePath: String?
        /// AXTitle — the app's display name.
        let title: String
        /// AXStatusLabel — the badge text ("3", "•"); nil/empty when unbadged.
        let badge: String?
    }

    /// A switcher app to look up.
    struct App: Equatable {
        let pid: pid_t
        let bundlePath: String?
        let name: String
    }

    /// Badge text per pid. An app matches its Dock item by bundle path first
    /// (exact), falling back to the title, and only non-blank badges count.
    static func match(items: [Item], apps: [App]) -> [pid_t: String] {
        var badges: [pid_t: String] = [:]
        for app in apps {
            let byPath = app.bundlePath.flatMap { path in items.first { $0.bundlePath == path } }
            let item = byPath ?? items.first { $0.title == app.name }
            guard let badge = item?.badge?.trimmingCharacters(in: .whitespacesAndNewlines), !badge.isEmpty else { continue }
            badges[app.pid] = badge
        }
        return badges
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
