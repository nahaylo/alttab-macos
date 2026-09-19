//
//  GlassStrength.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Pure mapping from the "Glass Strength" preference to the knobs the Liquid
//  Glass background can actually turn, extracted so it is unit-testable
//  without AppKit. NSGlassEffectView exposes no intensity property (macOS 26
//  SDK: contentView, cornerRadius, tintColor, style), so strength is emulated
//  on both sides of the default: toning DOWN lays an appearance-adaptive,
//  translucent window-background plate over the glass — the more opaque the
//  plate, the closer to the Solid background — and turning UP switches the
//  view to its clear style, the most see-through glass macOS offers.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import CoreGraphics

enum GlassStrength: String, CaseIterable {
    case light, medium, high, max

    /// Reproduces the look before the preference existed: regular glass, no plate.
    static let defaultLevel: GlassStrength = .high

    /// Resolves the stored preference; nil and unknown values fall back to the default.
    static func resolve(_ raw: String?) -> GlassStrength {
        raw.flatMap(GlassStrength.init(rawValue:)) ?? defaultLevel
    }

    /// Opacity of the window-background plate drawn over the glass. 0 leaves the
    /// glass untouched; higher values approach the Solid background.
    var plateAlpha: CGFloat {
        switch self {
        case .light: return 0.6
        case .medium: return 0.35
        case .high, .max: return 0
        }
    }

    /// Only the maximum level switches NSGlassEffectView to its clear style.
    var usesClearStyle: Bool {
        self == .max
    }

    /// Menu label.
    var title: String {
        switch self {
        case .light: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        case .max: return "Max"
        }
    }
}
