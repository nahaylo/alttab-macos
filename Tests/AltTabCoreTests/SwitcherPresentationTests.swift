//
//  SwitcherPresentationTests.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Unit tests for the Style preference and the Group-by-Application collapse.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import XCTest
@testable import AltTabCore

final class SwitcherPresentationTests: XCTestCase {

    private struct Win: Equatable {
        let id: CGWindowID
        let pid: pid_t
    }

    // MARK: - SwitcherStyle

    func testStyleDefaultIsIconsAndResolveFallsBack() {
        XCTAssertEqual(SwitcherStyle.defaultStyle, .icons)
        XCTAssertEqual(SwitcherStyle.resolve(nil), .icons)
        XCTAssertEqual(SwitcherStyle.resolve("grid"), .icons)
        XCTAssertEqual(SwitcherStyle.resolve("thumbnails"), .thumbnails)
        for style in SwitcherStyle.allCases {
            XCTAssertEqual(SwitcherStyle.resolve(style.rawValue), style)
        }
    }

    /// Icons style must never capture — that is the Screen Recording promise.
    func testOnlyThumbnailsStyleShowsPreviews() {
        XCTAssertTrue(SwitcherStyle.thumbnails.showsPreviews)
        XCTAssertFalse(SwitcherStyle.icons.showsPreviews)
    }

    func testThumbnailsMetricsAreFixedRegardlessOfCount() {
        let few = SwitcherStyle.thumbnails.metrics(count: 2, maxPanelWidth: 2000)
        let many = SwitcherStyle.thumbnails.metrics(count: 40, maxPanelWidth: 800)
        XCTAssertEqual(few, many)
        XCTAssertEqual(few.itemWidth, 180, "original cell width preserved")
        XCTAssertEqual(few.itemHeight, 160, "original cell height preserved")
        XCTAssertEqual(few.itemSpacing, 12)
        XCTAssertEqual(few.panelPaddingX, 20, "original panel padding preserved")
        XCTAssertEqual(few.panelPaddingY, 20)
        XCTAssertEqual(few.panelCornerRadius, 16, "original panel corners preserved")
        XCTAssertEqual(few.captionRowHeight, 0, "thumbnails label inside the cell")
    }

    func testIconsUseTheLargestIconWhenTheRowFits() {
        let m = SwitcherStyle.icons.metrics(count: 5, maxPanelWidth: 1500)
        XCTAssertEqual(m.iconSize, SwitcherStyle.maxIconSize)
        XCTAssertEqual(m.itemWidth, m.highlightSize, "the cell is the highlight wide (native pitch)")
        XCTAssertEqual(m.itemHeight, m.iconFrame, "and the image frame tall (no vertical clipping)")
        XCTAssertGreaterThan(m.iconFrame, m.iconSize, "frame includes the artwork's transparent margin")
        XCTAssertGreaterThan(m.highlightSize, m.iconSize, "highlight surrounds the visible icon")
        // The image overhangs the cell horizontally, but only within its own
        // transparent margin: nothing visible can be clipped.
        XCTAssertLessThanOrEqual((m.iconFrame - m.itemWidth) / 2, (m.iconFrame - m.iconSize) / 2)
        XCTAssertGreaterThan(m.captionRowHeight, 0, "caption row is where the selected name goes")
        XCTAssertEqual(m.panelHeight, m.panelPaddingY + m.itemHeight + m.captionRowHeight + m.panelPaddingBottom)
    }

    /// Native proportions, measured against the VISIBLE artwork: highlight,
    /// highlight-to-highlight gap and panel-edge-to-highlight padding all
    /// scale with it, so a shrunken row keeps the same look.
    func testIconsProportionsScaleWithTheVisibleIcon() {
        let big = SwitcherStyle.icons.metrics(count: 3, maxPanelWidth: 3000)
        let small = SwitcherStyle.icons.metrics(count: 60, maxPanelWidth: 800)
        for m in [big, small] {
            let v = m.iconSize
            XCTAssertEqual(m.iconFrame, (v / SwitcherStyle.iconArtworkFraction).rounded())
            XCTAssertEqual(m.highlightSize, (v * SwitcherStyle.highlightScale).rounded())
            XCTAssertEqual(m.itemSpacing, (v * SwitcherStyle.gapScale).rounded(), "highlight-to-highlight gap")
            XCTAssertEqual(m.panelPaddingX, (v * SwitcherStyle.sidePaddingScale).rounded(), "panel edge to highlight")
        }
        XCTAssertLessThan(small.itemSpacing, big.itemSpacing)
    }

    /// Icons may use nearly the whole screen width, like the Dock's switcher;
    /// Thumbnails keep their historical cap.
    func testIconsPanelMayRunWiderThanThumbnails() {
        XCTAssertEqual(SwitcherStyle.thumbnails.maxPanelWidthFraction, 0.85)
        XCTAssertGreaterThan(SwitcherStyle.icons.maxPanelWidthFraction, SwitcherStyle.thumbnails.maxPanelWidthFraction)
        XCTAssertLessThanOrEqual(SwitcherStyle.icons.maxPanelWidthFraction, 1.0)
    }

    /// Native puts the caption ~0.18 icon under the artwork and ends the
    /// panel ~0.1 icon under the text.
    func testIconsCaptionSitsAtNativeDistanceBelowTheArtwork() {
        let m = SwitcherStyle.icons.metrics(count: 5, maxPanelWidth: 3000)
        let artworkBottomToCaptionTop = (m.iconFrame - m.iconSize) / 2 + m.captionRowHeight - SwitcherStyle.captionTextHeight
        XCTAssertEqual(artworkBottomToCaptionTop, m.iconSize * SwitcherStyle.captionGapScale, accuracy: 1.5)
        XCTAssertEqual(m.panelPaddingBottom, (m.iconSize * SwitcherStyle.bottomPaddingScale).rounded())
        XCTAssertLessThan(m.panelPaddingBottom, m.panelPaddingY, "native is tighter below the caption than above the icons")
    }

    /// The case that motivated the retune: ~15 apps on a 2560pt display must
    /// not collapse back to the old 96pt cell.
    func testFifteenAppsOnAWideDisplayKeepLargeIcons() {
        let m = SwitcherStyle.icons.metrics(count: 15, maxPanelWidth: 2560 * SwitcherStyle.icons.maxPanelWidthFraction)
        XCTAssertEqual(m.iconSize, SwitcherStyle.maxIconSize, "room to spare → native ceiling, not a bigger icon")
    }

    /// Pixel-scanned off the Dock's switcher on a 2560pt display with 16–17
    /// apps: 104pt icons at a 134pt pitch. The model must reproduce it.
    func testSixteenAppsReproduceTheMeasuredNativeGeometry() {
        let m = SwitcherStyle.icons.metrics(count: 16, maxPanelWidth: 2560 * SwitcherStyle.icons.maxPanelWidthFraction)
        XCTAssertEqual(m.iconSize, 104)
        XCTAssertEqual(m.itemWidth + m.itemSpacing, 134, accuracy: 2, "icon pitch")
    }

    /// The native switcher shrinks icons as apps accumulate so the row keeps
    /// fitting the screen; the whole panel must fit the width given.
    func testIconsShrinkSoTheWholePanelFits() {
        let width: CGFloat = 1200
        let m = SwitcherStyle.icons.metrics(count: 10, maxPanelWidth: width)
        XCTAssertLessThan(m.iconSize, SwitcherStyle.maxIconSize)
        XCTAssertGreaterThanOrEqual(m.iconSize, SwitcherStyle.minIconSize)
        XCTAssertLessThanOrEqual(m.panelWidth(count: 10), width)
        // Monotonic: more items never yield a bigger icon.
        let more = SwitcherStyle.icons.metrics(count: 11, maxPanelWidth: width)
        XCTAssertLessThanOrEqual(more.iconSize, m.iconSize)
    }

    func testIconsStopShrinkingAtTheFloorAndLetTheStripScroll() {
        let width: CGFloat = 800
        let m = SwitcherStyle.icons.metrics(count: 60, maxPanelWidth: width)
        XCTAssertEqual(m.iconSize, SwitcherStyle.minIconSize)
        XCTAssertGreaterThan(m.panelWidth(count: 60), width, "past the floor the strip overflows and scrolls")
    }

    func testStripAndPanelWidthArithmetic() {
        let m = CellMetrics(iconSize: 0, iconFrame: 0, highlightSize: 0, itemWidth: 100, itemHeight: 100,
                            itemSpacing: 10, panelPaddingX: 15, panelPaddingY: 5, panelPaddingBottom: 7,
                            captionRowHeight: 20, panelCornerRadius: 8)
        XCTAssertEqual(m.stripWidth(count: 0), 0)
        XCTAssertEqual(m.stripWidth(count: 1), 100)
        XCTAssertEqual(m.stripWidth(count: 3), 320)
        XCTAssertEqual(m.panelWidth(count: 3), 350)
        XCTAssertEqual(m.panelHeight, 132)
    }

    /// Grouped lists are apps → app name (like the system switcher);
    /// ungrouped → window title, app name for untitled windows.
    func testCaptionPolicy() {
        XCTAssertEqual(SwitcherStyle.caption(windowTitle: "Inbox", appName: "Mail", grouped: true), "Mail")
        XCTAssertEqual(SwitcherStyle.caption(windowTitle: "Inbox", appName: "Mail", grouped: false), "Inbox")
        XCTAssertEqual(SwitcherStyle.caption(windowTitle: "", appName: "Mail", grouped: false), "Mail")
    }

    // MARK: - AppGrouping toggle

    func testGroupingIsOnByDefaultAndHonorsAnExplicitChoice() {
        XCTAssertTrue(AppGrouping.defaultEnabled)
        XCTAssertTrue(AppGrouping.resolve(nil))
        XCTAssertFalse(AppGrouping.resolve(false))
        XCTAssertTrue(AppGrouping.resolve(true))
    }

    // MARK: - AppGrouping.collapse

    func testCollapseKeepsFirstWindowPerAppInOrder() {
        let windows = [Win(id: 1, pid: 10), Win(id: 2, pid: 20), Win(id: 3, pid: 10),
                       Win(id: 4, pid: 30), Win(id: 5, pid: 20)]
        let grouped = AppGrouping.collapse(windows) { $0.pid }
        XCTAssertEqual(grouped, [Win(id: 1, pid: 10), Win(id: 2, pid: 20), Win(id: 4, pid: 30)])
    }

    func testCollapseIsIdentityWhenEveryWindowHasItsOwnApp() {
        let windows = [Win(id: 1, pid: 10), Win(id: 2, pid: 20)]
        XCTAssertEqual(AppGrouping.collapse(windows) { $0.pid }, windows)
    }

    func testCollapseOfEmptyListIsEmpty() {
        XCTAssertTrue(AppGrouping.collapse([Win]()) { $0.pid }.isEmpty)
    }

    // MARK: - DockBadges

    private let dockItems = [
        DockBadges.Item(bundlePath: "/Applications/Slack.app", title: "Slack", badge: "•"),
        DockBadges.Item(bundlePath: "/Applications/Mail.app", title: "Mail", badge: "12"),
        DockBadges.Item(bundlePath: "/Applications/Safari.app", title: "Safari", badge: nil),
        DockBadges.Item(bundlePath: "/Applications/Notes.app", title: "Notes", badge: "  "),
        DockBadges.Item(bundlePath: nil, title: "Visual Studio Code", badge: "1"),
    ]

    func testBadgesMatchByBundlePath() {
        let apps = [DockBadges.App(pid: 10, bundlePath: "/Applications/Mail.app", name: "Mail"),
                    DockBadges.App(pid: 20, bundlePath: "/Applications/Slack.app", name: "Slack")]
        XCTAssertEqual(DockBadges.match(items: dockItems, apps: apps), [10: "12", 20: "•"])
    }

    func testBadgesFallBackToTitleWhenTheDockGaveNoPath() {
        let apps = [DockBadges.App(pid: 30, bundlePath: "/Applications/Visual Studio Code.app", name: "Visual Studio Code")]
        XCTAssertEqual(DockBadges.match(items: dockItems, apps: apps), [30: "1"])
    }

    func testUnbadgedBlankAndUnknownAppsProduceNoEntry() {
        let apps = [DockBadges.App(pid: 1, bundlePath: "/Applications/Safari.app", name: "Safari"),
                    DockBadges.App(pid: 2, bundlePath: "/Applications/Notes.app", name: "Notes"),
                    DockBadges.App(pid: 3, bundlePath: "/Applications/Nope.app", name: "Nope")]
        XCTAssertTrue(DockBadges.match(items: dockItems, apps: apps).isEmpty)
    }

    /// The path match wins even when a differently-named item shares the title.
    func testBundlePathTakesPrecedenceOverTitle() {
        let items = [DockBadges.Item(bundlePath: "/Applications/A.app", title: "Mail", badge: "7"),
                     DockBadges.Item(bundlePath: "/Applications/Mail.app", title: "Mail", badge: "2")]
        let apps = [DockBadges.App(pid: 5, bundlePath: "/Applications/Mail.app", name: "Mail")]
        XCTAssertEqual(DockBadges.match(items: items, apps: apps), [5: "2"])
    }

    // MARK: - AppGrouping.representative

    func testRepresentativeIsTheWindowItselfWhenItSurvivedTheCollapse() {
        let full = [Win(id: 1, pid: 10), Win(id: 2, pid: 20)]
        let grouped = AppGrouping.collapse(full) { $0.pid }
        XCTAssertEqual(AppGrouping.representative(of: 2, in: grouped, full: full,
                                                   id: { $0.id }, ownerPID: { $0.pid }), 2)
    }

    /// The focused window was not its app's MRU-top window (stale cache):
    /// anchor on the app's survivor so the first Tab still moves to the
    /// previous app instead of re-selecting the current one.
    func testRepresentativeMapsACollapsedWindowToItsAppsSurvivor() {
        let full = [Win(id: 1, pid: 10), Win(id: 2, pid: 20), Win(id: 3, pid: 10)]
        let grouped = AppGrouping.collapse(full) { $0.pid }
        XCTAssertEqual(AppGrouping.representative(of: 3, in: grouped, full: full,
                                                   id: { $0.id }, ownerPID: { $0.pid }), 1)
    }

    func testRepresentativeIsNilForUnknownOrMissingFocus() {
        let full = [Win(id: 1, pid: 10)]
        let grouped = full
        XCTAssertNil(AppGrouping.representative(of: nil, in: grouped, full: full,
                                                id: { $0.id }, ownerPID: { $0.pid }))
        XCTAssertNil(AppGrouping.representative(of: 99, in: grouped, full: full,
                                                id: { $0.id }, ownerPID: { $0.pid }))
    }
}
