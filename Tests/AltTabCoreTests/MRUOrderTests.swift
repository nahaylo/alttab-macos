//
//  MRUOrderTests.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Unit tests for the MRU ordering logic used by WindowModel.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import XCTest
import CoreGraphics
@testable import AltTabCore

final class MRUOrderTests: XCTestCase {

    func testSeedReplacesOrder() {
        var mru = MRUOrder()
        mru.seed([3, 1, 2])
        XCTAssertEqual(mru.order, [3, 1, 2])
        mru.seed([5])
        XCTAssertEqual(mru.order, [5])
    }

    func testPromoteToFrontMovesExistingID() {
        var mru = MRUOrder()
        mru.seed([1, 2, 3])
        mru.promoteToFront(3)
        XCTAssertEqual(mru.order, [3, 1, 2])
    }

    func testPromoteToFrontInsertsUnknownID() {
        var mru = MRUOrder()
        mru.seed([1, 2])
        mru.promoteToFront(9)
        XCTAssertEqual(mru.order, [9, 1, 2])
    }

    func testPromoteToFrontIsIdempotentAtFront() {
        var mru = MRUOrder()
        mru.seed([1, 2])
        mru.promoteToFront(1)
        XCTAssertEqual(mru.order, [1, 2])
    }

    func testSyncPrunesStaleAndAppendsNewInInputOrder() {
        var mru = MRUOrder()
        mru.seed([1, 2, 3])
        mru.sync(with: [3, 1, 7, 5])
        XCTAssertEqual(mru.order, [1, 3, 7, 5])
    }

    func testSyncWithEmptyClearsOrder() {
        var mru = MRUOrder()
        mru.seed([1, 2])
        mru.sync(with: [])
        XCTAssertEqual(mru.order, [])
    }

    func testSortedOrdersByRankWithUnrankedLastPreservingInputOrder() {
        var mru = MRUOrder()
        mru.seed([20, 10])
        let items: [CGWindowID] = [10, 30, 20, 40]
        let sorted = mru.sorted(items) { $0 }
        XCTAssertEqual(sorted, [20, 10, 30, 40])
    }

    func testSortedEmptyOrderKeepsInputOrder() {
        let mru = MRUOrder()
        let items: [CGWindowID] = [4, 2, 9]
        XCTAssertEqual(mru.sorted(items) { $0 }, [4, 2, 9])
    }

    func testSortedAfterPromotionsReflectsRecency() {
        var mru = MRUOrder()
        mru.seed([1, 2, 3])
        mru.promoteToFront(2)
        mru.promoteToFront(3)
        let sorted = mru.sorted([1, 2, 3] as [CGWindowID]) { $0 }
        XCTAssertEqual(sorted, [3, 2, 1])
    }

    // MARK: - App ranks across window ID changes

    // Apps: terminal 1, safari 2, mail 3.
    private let terminal: pid_t = 1, safari: pid_t = 2, mail: pid_t = 3

    func testSeedWithOwnersRanksAppsByFirstWindow() {
        var mru = MRUOrder()
        mru.seed(windows: [(10, safari), (20, terminal), (11, safari), (30, mail)])
        XCTAssertEqual(mru.order, [10, 20, 11, 30])
        XCTAssertEqual(mru.appOrder, [safari, terminal, mail])
    }

    func testPromoteMovesTheAppToFrontToo() {
        var mru = MRUOrder()
        mru.seed(windows: [(10, safari), (20, terminal), (30, mail)])
        mru.promoteToFront(30, pid: mail)
        XCTAssertEqual(mru.appOrder, [mail, safari, terminal])
        // Without a pid, a window whose owner is known still moves its app.
        mru.promoteToFront(20)
        XCTAssertEqual(mru.appOrder, [terminal, mail, safari])
    }

    /// The reported bug: a Terminal tab moves to a new window ID. Before the
    /// fix the replacement was appended at the tail, so Terminal went from
    /// "previous app" to "last app" in the switcher.
    func testReplacedWindowKeepsItsAppsPlace() {
        var mru = MRUOrder()
        mru.seed(windows: [(10, safari), (20, terminal), (30, mail)])
        mru.promoteToFront(20, pid: terminal)   // working in Terminal
        mru.promoteToFront(10, pid: safari)     // switched to Safari
        XCTAssertEqual(mru.order, [10, 20, 30])
        // Terminal's visible tab now has window 21; 20 is gone.
        mru.sync(windows: [(10, safari), (21, terminal), (30, mail)])
        XCTAssertEqual(mru.order, [10, 21, 30])
        XCTAssertEqual(mru.sorted([30, 21, 10] as [CGWindowID]) { $0 }, [10, 21, 30])
    }

    func testWindowMissingForOneSyncReturnsToItsAppsPlace() {
        var mru = MRUOrder()
        mru.seed(windows: [(10, safari), (20, terminal), (30, mail)])
        mru.sync(windows: [(10, safari), (30, mail)])
        XCTAssertEqual(mru.order, [10, 30])
        mru.sync(windows: [(10, safari), (20, terminal), (30, mail)])
        XCTAssertEqual(mru.order, [10, 20, 30])
    }

    func testNewWindowOfARankedAppGoesAfterItsSiblings() {
        var mru = MRUOrder()
        mru.seed(windows: [(20, terminal), (10, safari)])
        mru.sync(windows: [(20, terminal), (10, safari), (22, terminal)])
        XCTAssertEqual(mru.order, [20, 22, 10])
    }

    func testWindowsOfUnknownAppsGoToTheTailInInputOrder() {
        var mru = MRUOrder()
        mru.seed(windows: [(10, safari), (20, terminal)])
        mru.sync(windows: [(10, safari), (40, 4), (20, terminal), (50, 5)])
        XCTAssertEqual(mru.order, [10, 20, 40, 50])
        XCTAssertEqual(mru.appOrder, [safari, terminal, 4, 5])
    }

    func testForgottenAppStartsUnranked() {
        var mru = MRUOrder()
        mru.seed(windows: [(20, terminal), (10, safari), (30, mail)])
        mru.sync(windows: [(10, safari), (30, mail)])
        mru.forgetApp(terminal)
        mru.sync(windows: [(10, safari), (30, mail), (25, terminal)])
        XCTAssertEqual(mru.order, [10, 30, 25])
    }

    func testOwnerlessEntriesRankBelowKnownApps() {
        var mru = MRUOrder()
        mru.seed([10, 20])                       // owner-less seed
        mru.promoteToFront(30, pid: terminal)
        mru.sync(windows: [(30, terminal), (10, safari), (20, mail), (31, terminal)])
        XCTAssertEqual(mru.order, [30, 31, 10, 20])
    }
}
