//
//  SwitcherSelectionTests.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Unit tests for the per-session selection logic. The scenarios mirror the
//  stale-cache bugs found in review: the displayed list can be missing the
//  currently focused window (created after the last gather) or contain ghost
//  windows (closed after it), so the first Tab must anchor against the actual
//  focused window, and reconcile must not cement a stale default.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import XCTest
@testable import AltTabCore

final class SwitcherSelectionTests: XCTestCase {

    // MARK: - Initial anchor

    func testAnchorsAtSlotOneWhenSlotZeroIsFocused() {
        // Fresh cache: [current, previous, older] — classic case.
        let index = SwitcherSelection.initialIndex(windowIDs: [1, 2, 3], focusedWindowID: 1)
        XCTAssertEqual(index, 1)
    }

    func testAnchorsAtSlotZeroWhenFocusedWindowMissingFromList() {
        // Stale cache: focused window 9 was created after the last gather, so
        // slot 0 already holds the true previous window.
        let index = SwitcherSelection.initialIndex(windowIDs: [1, 2, 3], focusedWindowID: 9)
        XCTAssertEqual(index, 0)
    }

    func testAnchorsAtSlotZeroWhenFocusedWindowRankedElsewhere() {
        // Corrupted MRU: focus is mid-list; the top-ranked non-focused window
        // is the best "previous" guess.
        let index = SwitcherSelection.initialIndex(windowIDs: [1, 2, 3], focusedWindowID: 2)
        XCTAssertEqual(index, 0)
    }

    func testAnchorsAtSlotOneWhenFocusUnknown() {
        let index = SwitcherSelection.initialIndex(windowIDs: [1, 2, 3], focusedWindowID: nil)
        XCTAssertEqual(index, 1)
    }

    func testSingleWindowAnchorsAtSlotZero() {
        XCTAssertEqual(SwitcherSelection.initialIndex(windowIDs: [1], focusedWindowID: 1), 0)
        XCTAssertEqual(SwitcherSelection.initialIndex(windowIDs: [1], focusedWindowID: nil), 0)
    }

    func testEmptyListAnchorsAtSlotZero() {
        XCTAssertEqual(SwitcherSelection.initialIndex(windowIDs: [], focusedWindowID: nil), 0)
    }

    func testActivateResetsCycledStateAndAnchors() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [1, 2, 3], focusedWindowID: 1)
        selection.cycleNext()
        XCTAssertTrue(selection.hasCycled)

        selection.activate(windowIDs: [4, 5], focusedWindowID: 4)
        XCTAssertFalse(selection.hasCycled)
        XCTAssertEqual(selection.selectedIndex, 1)
        XCTAssertEqual(selection.selectedID, 5)
    }

    // MARK: - Cycling

    func testCycleNextWrapsAround() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [1, 2, 3], focusedWindowID: 1)
        XCTAssertEqual(selection.selectedIndex, 1)
        selection.cycleNext()
        XCTAssertEqual(selection.selectedIndex, 2)
        selection.cycleNext()
        XCTAssertEqual(selection.selectedIndex, 0)
    }

    func testCyclePreviousWrapsAround() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [1, 2, 3], focusedWindowID: 1)
        selection.cyclePrevious()
        XCTAssertEqual(selection.selectedIndex, 0)
        selection.cyclePrevious()
        XCTAssertEqual(selection.selectedIndex, 2)
    }

    func testCycleOnEmptyListIsSafe() {
        var selection = SwitcherSelection()
        selection.cycleNext()
        selection.cyclePrevious()
        XCTAssertEqual(selection.selectedIndex, 0)
        XCTAssertNil(selection.selectedID)
    }

    func testSelectMarksIntentAndIgnoresOutOfBounds() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [1, 2, 3], focusedWindowID: 1)
        selection.select(index: 5)
        XCTAssertEqual(selection.selectedIndex, 1)
        XCTAssertFalse(selection.hasCycled)

        selection.select(index: 2)
        XCTAssertEqual(selection.selectedIndex, 2)
        XCTAssertTrue(selection.hasCycled)
    }

    // MARK: - Reconcile before the user cycles (re-anchor)

    func testReconcileReanchorsWhenNotCycled() {
        // Stale cache [B, A] with the focused window W uncached: the anchor
        // picks slot 0 (B). The fresh gather reveals [W, B, A]; the highlight
        // must stay on B — now slot 1, the true previous window.
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [20, 10], focusedWindowID: 30)
        XCTAssertEqual(selection.selectedIndex, 0)

        selection.reconcile(windowIDs: [30, 20, 10], focusedWindowID: 30)
        XCTAssertEqual(selection.selectedIndex, 1)
        XCTAssertEqual(selection.selectedID, 20)
    }

    func testReconcileReanchorsFromClassicDefaultWhenFocusWasUnknown() {
        // Focus undeterminable at activation (classic slot-1 default on the
        // stale list), fresh list shifts everything by one: re-anchor.
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [20, 10], focusedWindowID: nil)
        XCTAssertEqual(selection.selectedID, 10)

        selection.reconcile(windowIDs: [30, 20, 10], focusedWindowID: 30)
        XCTAssertEqual(selection.selectedID, 20)
    }

    func testReconcileKeepsAnchorWhenListUnchanged() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [1, 2, 3], focusedWindowID: 1)
        selection.reconcile(windowIDs: [1, 2, 3], focusedWindowID: 1)
        XCTAssertEqual(selection.selectedIndex, 1)
    }

    // MARK: - Reconcile after the user cycles (follow the window)

    func testReconcileFollowsSelectedWindowAfterCycle() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [20, 10], focusedWindowID: 20)
        selection.cycleNext() // deliberately onto 20's neighbor — wraps to 0
        XCTAssertEqual(selection.selectedID, 20)

        selection.reconcile(windowIDs: [30, 20, 10], focusedWindowID: 30)
        XCTAssertEqual(selection.selectedID, 20)
        XCTAssertEqual(selection.selectedIndex, 1)
    }

    func testReconcileFollowsClickedWindow() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [1, 2, 3], focusedWindowID: 1)
        selection.select(index: 2)
        selection.reconcile(windowIDs: [9, 3, 1, 2], focusedWindowID: 9)
        XCTAssertEqual(selection.selectedID, 3)
    }

    func testReconcileClampsWhenFollowedWindowVanished() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [1, 2, 3], focusedWindowID: 1)
        selection.cycleNext() // index 2, window 3
        selection.reconcile(windowIDs: [1, 2], focusedWindowID: 1)
        XCTAssertEqual(selection.selectedIndex, 1)
    }

    func testReconcileWithEmptyListResetsSafely() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [1, 2], focusedWindowID: 1)
        selection.reconcile(windowIDs: [], focusedWindowID: nil)
        XCTAssertEqual(selection.selectedIndex, 0)
        XCTAssertNil(selection.selectedID)
    }

    func testHasCycledPersistsAcrossReconciles() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [1, 2], focusedWindowID: 1)
        selection.cycleNext() // wraps to index 0, window 1
        XCTAssertEqual(selection.selectedID, 1)

        selection.reconcile(windowIDs: [3, 1, 2], focusedWindowID: 3)
        XCTAssertTrue(selection.hasCycled)
        XCTAssertEqual(selection.selectedID, 1)

        // A second reconcile must still follow the window, not re-anchor.
        selection.reconcile(windowIDs: [3, 2, 1], focusedWindowID: 3)
        XCTAssertEqual(selection.selectedID, 1)
        XCTAssertEqual(selection.selectedIndex, 2)
    }

    func testRepeatedReconcilesKeepReanchoringUntilUserCycles() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [2, 1], focusedWindowID: 2)
        XCTAssertEqual(selection.selectedID, 1)

        selection.reconcile(windowIDs: [3, 2, 1], focusedWindowID: 3)
        XCTAssertEqual(selection.selectedID, 2)

        selection.reconcile(windowIDs: [4, 3, 2, 1], focusedWindowID: 4)
        XCTAssertEqual(selection.selectedID, 3)
    }

    // MARK: - Confirmation order (ghost fall-through)

    func testConfirmationOrderStartsAtSelectionAndWraps() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [1, 2, 3], focusedWindowID: 1)
        XCTAssertEqual(selection.confirmationOrder, [2, 3, 1])
    }

    func testConfirmationOrderWithSelectionAtEnd() {
        var selection = SwitcherSelection()
        selection.activate(windowIDs: [1, 2, 3], focusedWindowID: 1)
        selection.cycleNext() // index 2
        XCTAssertEqual(selection.confirmationOrder, [3, 1, 2])
    }

    func testConfirmationOrderOnEmptyListIsEmpty() {
        let selection = SwitcherSelection()
        XCTAssertEqual(selection.confirmationOrder, [])
    }
}
