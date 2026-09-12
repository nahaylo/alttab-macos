//
//  DebouncerTests.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Unit tests for the trailing-edge debouncer that keeps the window cache
//  warm. Intervals are short but the assertions only depend on ordering
//  (fired once / not at all), not on tight timing.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import XCTest
@testable import AltTabCore

final class DebouncerTests: XCTestCase {

    func testFiresOnceAfterInterval() {
        var fireCount = 0
        let fired = expectation(description: "debounced action fired")
        let debouncer = Debouncer(interval: 0.05) {
            fireCount += 1
            fired.fulfill()
        }
        debouncer.schedule()
        XCTAssertTrue(debouncer.isPending)
        wait(for: [fired], timeout: 2.0)
        XCTAssertEqual(fireCount, 1)
        XCTAssertFalse(debouncer.isPending)
    }

    func testRapidSchedulesCoalesceIntoOneFire() {
        var fireCount = 0
        let fired = expectation(description: "debounced action fired")
        let debouncer = Debouncer(interval: 0.05) {
            fireCount += 1
            fired.fulfill()
        }
        debouncer.schedule()
        debouncer.schedule()
        debouncer.schedule()
        wait(for: [fired], timeout: 2.0)

        // Drain a couple of extra intervals to catch any spurious second fire.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)
        XCTAssertEqual(fireCount, 1)
    }

    func testCancelPreventsFire() {
        var fireCount = 0
        let debouncer = Debouncer(interval: 0.05) { fireCount += 1 }
        debouncer.schedule()
        debouncer.cancel()
        XCTAssertFalse(debouncer.isPending)

        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)
        XCTAssertEqual(fireCount, 0)
    }

    func testScheduleAfterCustomDelaySupersedesBaseInterval() {
        // Re-arming with a one-off delay (the rate-floor push-back) must
        // replace the pending base-interval fire, not add a second one.
        var fireCount = 0
        let fired = expectation(description: "debounced action fired")
        let debouncer = Debouncer(interval: 0.05) {
            fireCount += 1
            fired.fulfill()
        }
        debouncer.schedule()
        debouncer.schedule(after: 0.1)
        wait(for: [fired], timeout: 2.0)

        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)
        XCTAssertEqual(fireCount, 1)
    }

    func testReschedulingAfterFireWorks() {
        var fireCount = 0
        let firstFire = expectation(description: "first fire")
        let secondFire = expectation(description: "second fire")
        var debouncer: Debouncer!
        debouncer = Debouncer(interval: 0.05) {
            fireCount += 1
            if fireCount == 1 { firstFire.fulfill() }
            if fireCount == 2 { secondFire.fulfill() }
        }
        debouncer.schedule()
        wait(for: [firstFire], timeout: 2.0)
        debouncer.schedule()
        wait(for: [secondFire], timeout: 2.0)
        XCTAssertEqual(fireCount, 2)
    }
}
