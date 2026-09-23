//
//  DockClickTests.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Unit tests for the Dock click setting, policy and press → release gesture.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import XCTest
@testable import AltTabCore

final class DockClickTests: XCTestCase {

    private struct Win: Equatable {
        let id: CGWindowID
        let pid: pid_t
    }

    private let safari = DockBadges.App(pid: 10, bundlePath: "/Applications/Safari.app", name: "Safari")
    private let code = DockBadges.App(pid: 20, bundlePath: "/Applications/Visual Studio Code.app", name: "Code")
    private let mail = DockBadges.App(pid: 30, bundlePath: "/System/Applications/Mail.app", name: "Mail")
    private var apps: [DockBadges.App] { [safari, code, mail] }
    // MRU order: Code's window 21 is its most recent, Safari's 11 its most recent.
    private let windows = [Win(id: 21, pid: 20), Win(id: 11, pid: 10), Win(id: 22, pid: 20), Win(id: 12, pid: 10)]

    private func item(_ path: String?, _ title: String) -> DockBadges.Item {
        DockBadges.Item(bundlePath: path, title: title, badge: nil)
    }

    private func raise(_ item: DockBadges.Item?, frontmost: pid_t? = 99) -> Win? {
        DockClickPolicy.windowToRaise(item: item, apps: apps, frontmostPID: frontmost, windows: windows, ownerPID: { $0.pid })
    }

    // MARK: - Setting

    func testSettingDefaultsOnAndResolvesStoredValue() {
        XCTAssertTrue(DockClickSetting.defaultEnabled)
        XCTAssertTrue(DockClickSetting.resolve(nil))
        XCTAssertTrue(DockClickSetting.resolve(true))
        XCTAssertFalse(DockClickSetting.resolve(false))
        XCTAssertEqual(DockClickSetting.defaultsKey, "DockClickMostRecentWindow")
    }

    // MARK: - Policy

    func testOnlyAnUnmodifiedClickIsPlain() {
        XCTAssertTrue(DockClickPolicy.isPlainClick(commandDown: false, optionDown: false, controlDown: false, shiftDown: false))
        XCTAssertFalse(DockClickPolicy.isPlainClick(commandDown: true, optionDown: false, controlDown: false, shiftDown: false))
        XCTAssertFalse(DockClickPolicy.isPlainClick(commandDown: false, optionDown: true, controlDown: false, shiftDown: false))
        XCTAssertFalse(DockClickPolicy.isPlainClick(commandDown: false, optionDown: false, controlDown: true, shiftDown: false))
        XCTAssertFalse(DockClickPolicy.isPlainClick(commandDown: false, optionDown: false, controlDown: false, shiftDown: true))
    }

    func testItemMatchesByBundlePathBeforeTitle() {
        // Path wins even when the title names another app.
        XCTAssertEqual(DockClickPolicy.pid(for: item("/Applications/Safari.app", "Mail"), in: apps), 10)
        // No path: title.
        XCTAssertEqual(DockClickPolicy.pid(for: item(nil, "Mail"), in: apps), 30)
        // Unknown path and title: nothing.
        XCTAssertNil(DockClickPolicy.pid(for: item("/Applications/Xcode.app", "Xcode"), in: apps))
        // Blank title never matches an app with a blank name.
        XCTAssertNil(DockClickPolicy.pid(for: item(nil, ""), in: [DockBadges.App(pid: 5, bundlePath: nil, name: "")]))
    }

    func testRaisesTheAppsMostRecentWindow() {
        XCTAssertEqual(raise(item("/Applications/Visual Studio Code.app", "Code")), Win(id: 21, pid: 20))
        XCTAssertEqual(raise(item("/Applications/Safari.app", "Safari")), Win(id: 11, pid: 10))
    }

    func testLeavesTheClickToTheDockWhenNothingToRaise() {
        // Not an app item.
        XCTAssertNil(raise(nil))
        // App not running (unknown to the workspace).
        XCTAssertNil(raise(item("/Applications/Xcode.app", "Xcode")))
        // Running but no windows in the list (Mail): the Dock opens/reopens it.
        XCTAssertNil(raise(item("/System/Applications/Mail.app", "Mail")))
        // Already frontmost: the Dock's own click semantics (minimize / nothing) stay.
        XCTAssertNil(raise(item("/Applications/Safari.app", "Safari"), frontmost: 10))
    }

    func testDockStripFallbackGeometry() {
        // 2560×1440 screen, 38pt menu bar, 70pt Dock at the bottom (AppKit coordinates).
        let screens = [(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                        visibleFrame: CGRect(x: 0, y: 70, width: 2560, height: 1332))]
        // CGEvent points are top-left based: y = 1420 is 20pt above the bottom edge → Dock.
        XCTAssertTrue(DockClickPolicy.pointInDockStrip(CGPoint(x: 100, y: 1420), mainScreenHeight: 1440, screens: screens))
        // Inside the visible area.
        XCTAssertFalse(DockClickPolicy.pointInDockStrip(CGPoint(x: 100, y: 700), mainScreenHeight: 1440, screens: screens))
        // Menu bar is outside the visible frame too, but above it — not the Dock.
        XCTAssertFalse(DockClickPolicy.pointInDockStrip(CGPoint(x: 100, y: 10), mainScreenHeight: 1440, screens: screens))
        // Off every screen.
        XCTAssertFalse(DockClickPolicy.pointInDockStrip(CGPoint(x: 3000, y: 1420), mainScreenHeight: 1440, screens: screens))
        // Left-hand Dock on a second screen placed to the right.
        let two = screens + [(frame: CGRect(x: 2560, y: 0, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: 2640, y: 0, width: 1840, height: 1042))]
        XCTAssertTrue(DockClickPolicy.pointInDockStrip(CGPoint(x: 2600, y: 900), mainScreenHeight: 1440, screens: two))
        XCTAssertFalse(DockClickPolicy.pointInDockStrip(CGPoint(x: 2700, y: 900), mainScreenHeight: 1440, screens: two))
    }

    // MARK: - Gesture

    private typealias G = DockClickGesture
    private let p0 = CGPoint(x: 100, y: 1420)

    func testQuickClickOnInterceptedItemActivates() {
        var g = G()
        XCTAssertEqual(g.handle(.mouseDown(p0, 0)), G.Outcome(swallow: true, armHoldTimer: 1))
        XCTAssertTrue(g.isPending)
        XCTAssertEqual(g.handle(.decided(intercept: true)), .passThrough)
        XCTAssertEqual(g.handle(.mouseUp(p0, 0.1)), G.Outcome(swallow: true, activate: true))
        XCTAssertFalse(g.isPending)
        // The armed timer is stale now and must do nothing.
        XCTAssertEqual(g.handle(.holdTimeout(id: 1)), .passThrough)
    }

    func testReleaseBeforeDecisionIsHeldThenActivated() {
        var g = G()
        _ = g.handle(.mouseDown(p0, 0))
        XCTAssertEqual(g.handle(.mouseUp(p0, 0.08)), G.Outcome(swallow: true))
        XCTAssertTrue(g.isPending)
        XCTAssertEqual(g.handle(.decided(intercept: true)), G.Outcome(activate: true))
        XCTAssertFalse(g.isPending)
    }

    func testNegativeDecisionReplaysTheHeldPress() {
        var g = G()
        _ = g.handle(.mouseDown(p0, 0))
        XCTAssertEqual(g.handle(.decided(intercept: false)), G.Outcome(replay: true))
        XCTAssertFalse(g.isPending)
        // Afterwards the release is not ours.
        XCTAssertEqual(g.handle(.mouseUp(p0, 0.1)), .passThrough)
    }

    func testNegativeDecisionAfterReleaseReplaysBoth() {
        var g = G()
        _ = g.handle(.mouseDown(p0, 0))
        _ = g.handle(.mouseUp(p0, 0.05))
        XCTAssertEqual(g.handle(.decided(intercept: false)), G.Outcome(replay: true))
        XCTAssertFalse(g.isPending)
    }

    func testHoldReplaysToTheDockAndIgnoresTheLateRelease() {
        var g = G()
        _ = g.handle(.mouseDown(p0, 0))
        _ = g.handle(.decided(intercept: true))
        XCTAssertEqual(g.handle(.holdTimeout(id: g.id)), G.Outcome(replay: true))
        XCTAssertFalse(g.isPending)
        XCTAssertEqual(g.handle(.mouseUp(p0, 1.0)), .passThrough)
        XCTAssertEqual(g.handle(.decided(intercept: true)), .passThrough)
    }

    func testSlowHitTestDegradesToTheDocksOwnClick() {
        var g = G()
        _ = g.handle(.mouseDown(p0, 0))
        _ = g.handle(.mouseUp(p0, 0.1))
        // No decision by the hold threshold: the Dock gets the whole click.
        XCTAssertEqual(g.handle(.holdTimeout(id: g.id)), G.Outcome(replay: true))
        XCTAssertFalse(g.isPending)
        XCTAssertEqual(g.handle(.decided(intercept: true)), .passThrough)
    }

    func testDragReplaysOnceMovedPastThreshold() {
        var g = G()
        _ = g.handle(.mouseDown(p0, 0))
        let jitter = CGPoint(x: p0.x + 2, y: p0.y - 2)
        XCTAssertEqual(g.handle(.mouseDragged(jitter, 0.02)), G.Outcome(swallow: true))
        XCTAssertTrue(g.isPending)
        let far = CGPoint(x: p0.x + 10, y: p0.y)
        XCTAssertEqual(g.handle(.mouseDragged(far, 0.05)), G.Outcome(swallow: true, replay: true))
        XCTAssertFalse(g.isPending)
        XCTAssertEqual(g.handle(.mouseDragged(far, 0.06)), .passThrough)
    }

    func testJitterDoesNotCancelTheClick() {
        var g = G()
        _ = g.handle(.mouseDown(p0, 0))
        _ = g.handle(.mouseDragged(CGPoint(x: p0.x + 3, y: p0.y), 0.02))
        _ = g.handle(.decided(intercept: true))
        XCTAssertEqual(g.handle(.mouseUp(p0, 0.1)), G.Outcome(swallow: true, activate: true))
    }

    func testSecondPressWhilePendingGivesTheFirstBackAndPasses() {
        var g = G()
        _ = g.handle(.mouseDown(p0, 0))
        XCTAssertEqual(g.handle(.mouseDown(p0, 0.05)), G.Outcome(swallow: false, replay: true))
        XCTAssertFalse(g.isPending)
    }

    func testStaleHoldTimerFromAnEarlierPressIsIgnored() {
        var g = G()
        _ = g.handle(.mouseDown(p0, 0))
        _ = g.handle(.decided(intercept: true))
        _ = g.handle(.mouseUp(p0, 0.1))
        let first = g.id
        _ = g.handle(.mouseDown(p0, 1))
        XCTAssertEqual(g.handle(.holdTimeout(id: first)), .passThrough)
        XCTAssertTrue(g.isPending)
        XCTAssertEqual(g.handle(.holdTimeout(id: g.id)), G.Outcome(replay: true))
    }

    func testEventsOutsideAPressPassThrough() {
        var g = G()
        XCTAssertEqual(g.handle(.mouseDragged(p0, 0)), .passThrough)
        XCTAssertEqual(g.handle(.mouseUp(p0, 0)), .passThrough)
        XCTAssertEqual(g.handle(.decided(intercept: true)), .passThrough)
        XCTAssertEqual(g.handle(.holdTimeout(id: 0)), .passThrough)
    }
}
