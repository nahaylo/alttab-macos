//
//  GlassStrengthTests.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Unit tests for the Glass Strength preference mapping. They pin the two
//  promises the UI relies on: the default reproduces the pre-preference look,
//  and the scale is monotonic — each step toward Light adds plate opacity,
//  and only Max flips the glass to its clear style.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import XCTest
@testable import AltTabCore

final class GlassStrengthTests: XCTestCase {

    func testDefaultIsHighAndKeepsRegularGlassUntouched() {
        XCTAssertEqual(GlassStrength.defaultLevel, .high)
        XCTAssertEqual(GlassStrength.high.plateAlpha, 0)
        XCTAssertFalse(GlassStrength.high.usesClearStyle)
    }

    func testResolveFallsBackToDefaultForMissingOrUnknownValues() {
        XCTAssertEqual(GlassStrength.resolve(nil), .high)
        XCTAssertEqual(GlassStrength.resolve(""), .high)
        XCTAssertEqual(GlassStrength.resolve("ultra"), .high)
        XCTAssertEqual(GlassStrength.resolve("Light"), .high, "raw values are case-sensitive lowercase")
    }

    func testResolveMapsEveryStoredValue() {
        for level in GlassStrength.allCases {
            XCTAssertEqual(GlassStrength.resolve(level.rawValue), level)
        }
    }

    func testScaleOrderIsLightToMax() {
        XCTAssertEqual(GlassStrength.allCases, [.light, .medium, .high, .max])
    }

    func testPlateOpacityDecreasesTowardMaxAndStaysInRange() {
        let alphas = GlassStrength.allCases.map { $0.plateAlpha }
        for (weaker, stronger) in zip(alphas, alphas.dropFirst()) {
            XCTAssertGreaterThanOrEqual(weaker, stronger)
        }
        XCTAssertGreaterThan(GlassStrength.light.plateAlpha, GlassStrength.medium.plateAlpha)
        XCTAssertGreaterThan(GlassStrength.medium.plateAlpha, GlassStrength.high.plateAlpha)
        for alpha in alphas {
            XCTAssertGreaterThanOrEqual(alpha, 0)
            XCTAssertLessThanOrEqual(alpha, 1)
        }
    }

    func testOnlyMaxUsesClearStyle() {
        XCTAssertEqual(GlassStrength.allCases.filter { $0.usesClearStyle }, [.max])
        XCTAssertEqual(GlassStrength.max.plateAlpha, 0, "clear glass must not be dimmed by a plate")
    }

    func testTitlesAreUniqueAndNonEmpty() {
        let titles = GlassStrength.allCases.map { $0.title }
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertFalse(titles.contains(where: { $0.isEmpty }))
    }
}
