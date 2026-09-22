//
//  ThumbnailView.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  A single cell in the switcher strip, drawn in one of two styles
//  (SwitcherStyle):
//
//  - Thumbnails: the window preview (or app icon fallback), window title and
//    application name; the selected cell gets an accent-colored border and a
//    subtle background tint.
//  - Icons: the native Cmd-Tab look — one large app icon with a filled
//    rounded highlight behind the selected one, and the app's Dock badge
//    (unread count / dot) at the artwork's top-right corner. Minimized
//    windows dim. The caption under the selected icon is drawn by
//    SwitcherPanel, not the cell, so it can span the panel instead of
//    truncating at the cell width.
//
//  Supports mouse hover and click interaction for direct window selection.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  Version: 1.3.0
//  Date:    2026-07-02
//  License: MIT
//

import Cocoa

final class ThumbnailView: NSView {

    var onClicked: (() -> Void)?

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    /// Secondary tone for the app name that stays dynamic across appearance
    /// changes — withAlphaComponent() on a catalog color resolves and freezes
    /// it at call time, which would pin the wrong theme's color (cells are
    /// constructed before joining the panel's forced-appearance hierarchy).
    private static let appNameColor = NSColor(name: nil) { appearance in
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.withAlphaComponent(0.78)
        }
        return color
    }

    let ownerPID: pid_t
    private let style: SwitcherStyle
    private let metrics: CellMetrics
    private var badgeView: NSView?
    private var badgeLabel: NSTextField?
    private let imageView: NSImageView
    private let titleLabel: NSTextField
    private let appLabel: NSTextField
    /// Thumbnails: the accent border. Icons: the filled selection highlight.
    private let selectionView: NSView
    private let isMinimized: Bool

    init(windowInfo: WindowInfo, style: SwitcherStyle, metrics: CellMetrics) {
        self.ownerPID = windowInfo.ownerPID
        self.style = style
        self.metrics = metrics
        self.isMinimized = windowInfo.isMinimized

        imageView = NSImageView()
        titleLabel = NSTextField(labelWithString: "")
        appLabel = NSTextField(labelWithString: "")
        selectionView = NSView()

        super.init(frame: NSRect(x: 0, y: 0, width: metrics.itemWidth, height: metrics.itemHeight))

        switch style {
        case .thumbnails: setupThumbnailViews()
        case .icons: setupIconViews()
        }
        configure(with: windowInfo)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Setup: Thumbnails style

    private func setupThumbnailViews() {
        wantsLayer = true
        let width = metrics.itemWidth
        let height = metrics.itemHeight
        let thumbnailHeight = height - 50 // Reserve space for labels

        // Selection border
        selectionView.wantsLayer = true
        selectionView.layer?.borderWidth = 3
        selectionView.layer?.cornerRadius = 8
        selectionView.layer?.borderColor = NSColor.clear.cgColor
        selectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionView)

        // Thumbnail image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        // Window title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // App name
        appLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        appLabel.textColor = Self.appNameColor
        appLabel.alignment = .center
        appLabel.lineBreakMode = .byTruncatingTail
        appLabel.maximumNumberOfLines = 1
        appLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(appLabel)

        NSLayoutConstraint.activate([
            // Selection border fills entire view
            selectionView.topAnchor.constraint(equalTo: topAnchor),
            selectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            selectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Image at top
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: width - 16),
            imageView.heightAnchor.constraint(equalToConstant: thumbnailHeight),

            // Title below image
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            // App name below title
            appLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            appLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            appLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            // Fixed size
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    // MARK: - Setup: Icons style

    private func setupIconViews() {
        wantsLayer = true
        let width = metrics.itemWidth
        let height = metrics.itemHeight
        // The image frame is larger than the visible artwork (icons carry a
        // transparent margin); the highlight — a fifth larger than the
        // artwork, like the native switcher's — sits inside it, and its
        // radius scales with it.
        let icon = metrics.iconFrame
        let highlightSize = metrics.highlightSize

        selectionView.wantsLayer = true
        selectionView.layer?.cornerRadius = (highlightSize * 0.22).rounded()
        selectionView.layer?.backgroundColor = NSColor.clear.cgColor
        selectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionView)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            selectionView.centerXAnchor.constraint(equalTo: centerXAnchor),
            selectionView.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionView.widthAnchor.constraint(equalToConstant: highlightSize),
            selectionView.heightAnchor.constraint(equalToConstant: highlightSize),

            imageView.centerXAnchor.constraint(equalTo: selectionView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: selectionView.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: icon),
            imageView.heightAnchor.constraint(equalToConstant: icon),

            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    // MARK: - Content

    private func configure(with windowInfo: WindowInfo) {
        titleLabel.stringValue = windowInfo.windowTitle.isEmpty ? windowInfo.ownerName : windowInfo.windowTitle
        appLabel.stringValue = windowInfo.ownerName

        switch style {
        case .icons:
            imageView.image = windowInfo.appIcon
            if isMinimized {
                imageView.alphaValue = 0.55
            }

        case .thumbnails:
            if let thumbnail = windowInfo.thumbnail {
                imageView.image = thumbnail
            } else {
                // Fallback: app icon
                imageView.image = windowInfo.appIcon
                if isMinimized {
                    imageView.alphaValue = 0.7
                }
            }
        }

        #if DEBUG
        // Regression tripwire for the WCAG AA guarantee on the solid default
        // background (spec 2026-07-02-switcher-background-styles).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB),
               let fg = NSColor.labelColor.usingColorSpace(.sRGB) {
                let ratio = WCAGContrast.contrastRatio(
                    text: SRGB(r: fg.redComponent, g: fg.greenComponent,
                               b: fg.blueComponent, a: fg.alphaComponent),
                    background: SRGB(r: bg.redComponent, g: bg.greenComponent,
                                     b: bg.blueComponent, a: bg.alphaComponent))
                assert(ratio >= 4.5, "Switcher label contrast fell below WCAG AA: \(ratio)")
            }
        }
        #endif
    }

    // MARK: - Badge (Icons style)

    /// Shows the app's Dock badge — a red pill with the text — at the visible
    /// artwork's top-right corner like the native switcher; nil removes it.
    /// Thumbnails style ignores badges (its image is a window preview).
    func setBadge(_ text: String?) {
        guard style == .icons else { return }
        guard let text = text, !text.isEmpty else {
            badgeView?.removeFromSuperview()
            badgeView = nil
            badgeLabel = nil
            return
        }
        if badgeView == nil {
            let pill = NSView()
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.systemRed.cgColor
            let label = NSTextField(labelWithString: "")
            label.textColor = .white
            label.alignment = .center
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            pill.addSubview(label)
            addSubview(pill)
            badgeView = pill
            badgeLabel = label
        }
        badgeLabel?.stringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let pill = badgeView, let label = badgeLabel else { return }
        // Native (pixel-measured): badge diameter ~0.31 of the icon, centred
        // ~0.08 icon inward from the artwork's top-right corner; multi-
        // character text widens it into a pill.
        let icon = metrics.iconSize
        let diameter = max(18, (icon * 0.31).rounded())
        label.font = NSFont.systemFont(ofSize: (diameter * 0.58).rounded(), weight: .bold)
        label.sizeToFit()
        let width = max(diameter, label.frame.width + diameter * 0.5)
        let inset = (icon * 0.08).rounded()
        let cornerX = bounds.midX + icon / 2 - inset
        let cornerY = bounds.midY + icon / 2 - inset
        pill.frame = NSRect(x: (cornerX - width / 2).rounded(), y: (cornerY - diameter / 2).rounded(),
                            width: width, height: diameter)
        pill.layer?.cornerRadius = diameter / 2
        label.frame = NSRect(x: 0, y: ((diameter - label.frame.height) / 2).rounded(),
                             width: width, height: label.frame.height)
    }

    /// Replaces the app-icon placeholder with a captured window preview.
    /// Icons style has no preview area and ignores it (captures are never
    /// started for it anyway — SwitcherStyle.showsPreviews).
    func setThumbnail(_ image: NSImage) {
        guard style == .thumbnails else { return }
        imageView.image = image
        imageView.alphaValue = 1.0
    }

    // MARK: - Selection / hover

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch style {
            case .thumbnails:
                if isSelected {
                    selectionView.layer?.borderColor = NSColor.controlAccentColor.cgColor
                    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
                } else {
                    selectionView.layer?.borderColor = NSColor.clear.cgColor
                    layer?.backgroundColor = NSColor.clear.cgColor
                }

            case .icons:
                selectionView.layer?.backgroundColor = isSelected
                    ? NSColor.labelColor.withAlphaComponent(0.09).cgColor
                    : NSColor.clear.cgColor
            }
        }
    }

    private func setHover(_ hovering: Bool) {
        guard !isSelected else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = hovering ? NSColor.labelColor.withAlphaComponent(0.06).cgColor : NSColor.clear.cgColor
            switch style {
            case .thumbnails: layer?.backgroundColor = color
            case .icons: selectionView.layer?.backgroundColor = color
            }
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        onClicked?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        setHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHover(false)
    }
}
