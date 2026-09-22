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

    /// Largest VISIBLE icon edge for Icons style (what the native switcher
    /// draws for a handful of apps) and the floor it shrinks to before
    /// scrolling. "Visible" because macOS app icons carry a transparent
    /// margin: the artwork fills only ~80% of the image (the 824/1024 icon
    /// grid), so every proportion below is relative to the artwork and the
    /// image frame is enlarged to compensate — sizing to the frame made all
    /// the paddings come out a quarter too big.
    static let maxIconSize: CGFloat = 128
    static let minIconSize: CGFloat = 48
    static let iconArtworkFraction: CGFloat = 0.8
    /// Native proportions, relative to the visible icon edge (measured off
    /// same-scale photos of the Dock's switcher): the selection highlight is
    /// a fifth larger than the icon, highlights nearly touch (icons 0.22
    /// apart), the panel edge is 0.16 icon beyond the outer highlights (0.25
    /// beyond the icon), and the panel top sits 0.25 icon above the icon.
    static let highlightScale: CGFloat = 1.2
    static let gapScale: CGFloat = 0.03
    static let sidePaddingScale: CGFloat = 0.16
    static let topPaddingScale: CGFloat = 0.25
    /// Below the icon: the caption's top sits captionGapScale of an icon
    /// under the artwork — right at the highlight's bottom edge — and the
    /// panel ends bottomPaddingScale under the caption text.
    static let captionGapScale: CGFloat = 0.08
    static let bottomPaddingScale: CGFloat = 0.08
    /// Caption text height budget (13pt system font).
    static let captionTextHeight: CGFloat = 16

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
            return CellMetrics(iconSize: 0, iconFrame: 0, highlightSize: 0, itemWidth: 180, itemHeight: 160,
                               itemSpacing: 12, panelPaddingX: 20, panelPaddingY: 20, panelPaddingBottom: 20,
                               captionRowHeight: 0, panelCornerRadius: 16)
        case .icons:
            let n = CGFloat(max(1, count))
            // Everything in units of the visible icon edge v. The cell is the
            // image frame (v / artworkFraction); the highlight sits inside it.
            let frameScale = 1 / Self.iconArtworkFraction                    // 1.25
            let frameOverhang = frameScale - Self.highlightScale             // frame beyond highlight, both sides
            let cellGapScale = Self.gapScale - frameOverhang                 // cell gap giving the highlight gap
            let edgePadScale = Self.sidePaddingScale - frameOverhang / 2     // panel edge → first cell
            let perIcon = frameScale * n + cellGapScale * (n - 1) + 2 * edgePadScale
            // Panel top → icon top is topPaddingScale of the icon; the frame's
            // own margin above the artwork supplies part of that.
            let frameMarginScale = (frameScale - 1) / 2

            func build(_ visible: CGFloat) -> CellMetrics {
                let frame = (visible * frameScale).rounded()
                // The caption row starts at the cell's bottom edge, which is
                // already frameMargin below the artwork — more than the native
                // caption gap, so the row is shorter than the text and the
                // caption overlaps the cell's transparent bottom margin.
                let captionRow = max(0, (visible * (Self.captionGapScale - frameMarginScale)).rounded() + Self.captionTextHeight)
                return CellMetrics(iconSize: visible, iconFrame: frame,
                                   highlightSize: (visible * Self.highlightScale).rounded(),
                                   itemWidth: frame, itemHeight: frame,
                                   itemSpacing: max(0, (visible * cellGapScale).rounded()),
                                   panelPaddingX: max(0, (visible * edgePadScale).rounded()),
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
