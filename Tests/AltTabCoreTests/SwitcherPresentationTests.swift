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

    func testIconsStyleGeometryFitsTheIconWithRoomForATitle() {
        let icons = SwitcherStyle.icons
        XCTAssertGreaterThan(icons.iconSize, 0)
        XCTAssertGreaterThan(icons.itemWidth, icons.iconSize)
        XCTAssertGreaterThan(icons.itemHeight, icons.iconSize + 20, "no room for the title row")
        XCTAssertEqual(SwitcherStyle.thumbnails.itemWidth, 180, "original cell width preserved")
        XCTAssertEqual(SwitcherStyle.thumbnails.itemHeight, 160, "original cell height preserved")
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
