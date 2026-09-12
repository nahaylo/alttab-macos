//
//  GatherMergeTests.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Unit tests for the lossy-gather merge policy. The regression they pin
//  down: one 0.25s AX timeout in one app must not drop that app's windows
//  from the switcher or destroy their MRU ranks (pruned by sync(), then
//  re-appended at the tail by the next successful gather).
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import XCTest
import CoreGraphics
@testable import AltTabCore

final class GatherMergeTests: XCTestCase {

    private struct Win: Equatable {
        let id: CGWindowID
        let pid: pid_t
    }

    private func merge(previous: [Win], gathered: [Win], unresponsive: Set<pid_t>) -> [Win] {
        GatherMerge.merge(previous: previous,
                          gathered: gathered,
                          unresponsivePIDs: unresponsive,
                          id: { $0.id },
                          ownerPID: { $0.pid })
    }

    func testNoUnresponsiveAppsReturnsGatheredUnchanged() {
        let previous = [Win(id: 1, pid: 100), Win(id: 2, pid: 200)]
        let gathered = [Win(id: 1, pid: 100)]
        XCTAssertEqual(merge(previous: previous, gathered: gathered, unresponsive: []), gathered)
    }

    func testCarriesOverWindowsOfUnresponsiveApp() {
        // App 200 timed out: its windows 2 and 3 are missing from the gather
        // but must be carried over, after the gathered entries.
        let previous = [Win(id: 1, pid: 100), Win(id: 2, pid: 200), Win(id: 3, pid: 200)]
        let gathered = [Win(id: 1, pid: 100)]
        let merged = merge(previous: previous, gathered: gathered, unresponsive: [200])
        XCTAssertEqual(merged, [Win(id: 1, pid: 100), Win(id: 2, pid: 200), Win(id: 3, pid: 200)])
    }

    func testDoesNotDuplicateWindowsTheGatherStillFound() {
        // The unresponsive app's ON-SCREEN window still arrives via the CG
        // list; only its missing (off-screen) windows are carried over — and
        // the fresh entry wins over the cached one.
        let previous = [Win(id: 2, pid: 200), Win(id: 3, pid: 200)]
        let gathered = [Win(id: 2, pid: 200)]
        let merged = merge(previous: previous, gathered: gathered, unresponsive: [200])
        XCTAssertEqual(merged, [Win(id: 2, pid: 200), Win(id: 3, pid: 200)])
    }

    func testDropsMissingWindowsOfResponsiveApps() {
        // App 100 answered and window 1 is gone: genuinely closed, pruned.
        let previous = [Win(id: 1, pid: 100), Win(id: 2, pid: 200)]
        let gathered = [Win(id: 2, pid: 200)]
        let merged = merge(previous: previous, gathered: gathered, unresponsive: [])
        XCTAssertEqual(merged, [Win(id: 2, pid: 200)])
    }

    func testCarriedWindowsPreservePreviousRelativeOrder() {
        let previous = [Win(id: 5, pid: 200), Win(id: 4, pid: 200), Win(id: 6, pid: 200)]
        let gathered: [Win] = []
        let merged = merge(previous: previous, gathered: gathered, unresponsive: [200])
        XCTAssertEqual(merged.map { $0.id }, [5, 4, 6])
    }

    func testEmptyPreviousCacheCarriesNothing() {
        let gathered = [Win(id: 1, pid: 100)]
        XCTAssertEqual(merge(previous: [], gathered: gathered, unresponsive: [200]), gathered)
    }

    // MARK: - End-to-end rank preservation through MRUOrder.sync

    func testCarryOverPreservesMRURanksAcrossALossyGather() {
        // MRU says 3 (app 200) is most recent. A gather misses app 200
        // entirely (timeout). Without the merge, sync() would prune 3 and 2
        // and the next gather would re-append them at the tail — rank
        // amnesia. With the merge, ranks survive both gathers.
        var mru = MRUOrder()
        mru.seed([3, 1, 2])
        let previous = [Win(id: 1, pid: 100), Win(id: 2, pid: 200), Win(id: 3, pid: 200)]

        // Lossy gather: only app 100 answered.
        let lossy = merge(previous: previous,
                          gathered: [Win(id: 1, pid: 100)],
                          unresponsive: [200])
        mru.sync(with: lossy.map { $0.id })
        XCTAssertEqual(mru.order, [3, 1, 2])

        // Next gather: app 200 answers again.
        let full = merge(previous: lossy,
                         gathered: previous,
                         unresponsive: [])
        mru.sync(with: full.map { $0.id })
        XCTAssertEqual(mru.order, [3, 1, 2])
        XCTAssertEqual(mru.sorted(full) { $0.id }.map { $0.id }, [3, 1, 2])
    }

    func testWithoutCarryOverRanksWouldBeDestroyed() {
        // Counterfactual documenting the bug the merge prevents: feeding the
        // lossy list straight into sync() demotes the missed app's windows.
        var mru = MRUOrder()
        mru.seed([3, 1, 2])
        mru.sync(with: [1])          // lossy gather, no carry-over
        mru.sync(with: [1, 2, 3])    // app answers again → re-appended at tail
        XCTAssertEqual(mru.order, [1, 2, 3])
        XCTAssertNotEqual(mru.order, [3, 1, 2])
    }
}
