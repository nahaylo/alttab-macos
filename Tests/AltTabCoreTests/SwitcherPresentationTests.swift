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

    func testStyleDefaultIsThumbnailsAndResolveFallsBack() {
        XCTAssertEqual(SwitcherStyle.defaultStyle, .thumbnails)
        XCTAssertEqual(SwitcherStyle.resolve(nil), .thumbnails)
        XCTAssertEqual(SwitcherStyle.resolve("grid"), .thumbnails)
        XCTAssertEqual(SwitcherStyle.resolve("icons"), .icons)
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
        XCTAssertEqual(SwitcherStyle.thumbnails.captionRowHeight, 0, "thumbnails label inside the cell")
    }

    func testIconsUseTheLargestIconWhenTheRowFits() {
        let m = SwitcherStyle.icons.metrics(count: 5, maxPanelWidth: 1500)
        XCTAssertEqual(m.iconSize, SwitcherStyle.maxIconSize)
        XCTAssertEqual(m.itemWidth, m.itemHeight, "icon cells are square")
        XCTAssertGreaterThan(m.highlightSize, m.iconSize, "highlight surrounds the icon")
        XCTAssertGreaterThanOrEqual(m.itemHeight, m.highlightSize, "highlight must fit the cell")
        XCTAssertGreaterThan(SwitcherStyle.icons.captionRowHeight, 0, "caption row is where the selected name goes")
    }

    /// Native proportions: highlight, gap and side padding all scale with the
    /// icon, so a shrunken row keeps the same look rather than cramming.
    func testIconsProportionsScaleWithTheIcon() {
        let big = SwitcherStyle.icons.metrics(count: 3, maxPanelWidth: 3000)
        let small = SwitcherStyle.icons.metrics(count: 60, maxPanelWidth: 800)
        for m in [big, small] {
            XCTAssertEqual(m.highlightSize, (m.iconSize * SwitcherStyle.highlightScale).rounded())
            XCTAssertEqual(m.itemSpacing, (m.iconSize * SwitcherStyle.gapScale).rounded())
            XCTAssertEqual(m.panelPaddingX, (m.iconSize * SwitcherStyle.sidePaddingScale).rounded())
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

    /// The case that motivated the retune: ~15 apps on a 2560pt display must
    /// not collapse back to the old 96pt cell.
    func testFifteenAppsOnAWideDisplayKeepLargeIcons() {
        let m = SwitcherStyle.icons.metrics(count: 15, maxPanelWidth: 2560 * SwitcherStyle.icons.maxPanelWidthFraction)
        XCTAssertGreaterThanOrEqual(m.iconSize, 112)
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
        let m = CellMetrics(iconSize: 0, highlightSize: 0, itemWidth: 100, itemHeight: 100, itemSpacing: 10,
                            panelPaddingX: 15, panelPaddingY: 5, panelCornerRadius: 8)
        XCTAssertEqual(m.stripWidth(count: 0), 0)
        XCTAssertEqual(m.stripWidth(count: 1), 100)
        XCTAssertEqual(m.stripWidth(count: 3), 320)
        XCTAssertEqual(m.panelWidth(count: 3), 350)
    }

    /// Grouped lists are apps → app name (like the system switcher);
    /// ungrouped → window title, app name for untitled windows.
    func testCaptionPolicy() {
        XCTAssertEqual(SwitcherStyle.caption(windowTitle: "Inbox", appName: "Mail", grouped: true), "Mail")
        XCTAssertEqual(SwitcherStyle.caption(windowTitle: "Inbox", appName: "Mail", grouped: false), "Inbox")
        XCTAssertEqual(SwitcherStyle.caption(windowTitle: "", appName: "Mail", grouped: false), "Mail")
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
