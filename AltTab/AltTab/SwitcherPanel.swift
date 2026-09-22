//
//  SwitcherPanel.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  The overlay UI that displays window thumbnails in a horizontal strip.
//  Built as an NSPanel with .nonactivatingPanel style mask so it floats
//  above all windows without stealing focus — critical for the Option-release
//  activation flow. The background is user-selectable (status menu →
//  Background): an opaque solid plate (default, WCAG AA-tested label
//  contrast), the classic translucent HUD material, native Liquid Glass on
//  macOS 26+, or "System" — whatever the Dock's own app switcher draws on
//  the running OS (regular Liquid Glass on 26+, the HUD material before).
//  Content lives in an NSScrollView wrapping a horizontal NSStackView of
//  ThumbnailView cells, sized per the Style preference (SwitcherStyle). Appears centered on the screen that
//  contains the mouse pointer. Thumbnail clicks are reported through the
//  onWindowClicked callback; previews arriving later are patched into cells
//  in place via updateThumbnail(windowID:image:).
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  Version: 1.3.3
//  Date:    2026-09-19
//  License: MIT
//

import Cocoa

final class SwitcherPanel: NSPanel {

    /// Called with the cell index when the user clicks a thumbnail.
    var onWindowClicked: ((Int) -> Void)?

    /// UserDefaults key for the appearance override: absent/"system", "light", or "dark".
    static let appearanceDefaultsKey = "AppearanceOverride"

    /// UserDefaults key for the panel background style: absent/"solid",
    /// "transparent", "glass", or "system".
    static let backgroundDefaultsKey = "BackgroundStyle"

    /// UserDefaults key for the Liquid Glass strength: absent/"high" (the
    /// original look), "light", "medium", or "max". Only used with "glass".
    static let glassStrengthDefaultsKey = "GlassStrength"

    private static func currentGlassStrength() -> GlassStrength {
        GlassStrength.resolve(UserDefaults.standard.string(forKey: glassStrengthDefaultsKey))
    }

    private enum BackgroundStyle: String {
        case solid, transparent, glass, system

        /// Resolves the stored preference to a drawable style plus the glass
        /// strength to draw it with. Unknown values map to solid; "glass"
        /// falls back to solid on macOS < 26 where NSGlassEffectView does not
        /// exist; "system" is what the Dock's own switcher draws on this OS —
        /// regular Liquid Glass (the default strength, no plate) on 26+, the
        /// translucent HUD material before — so it never returns .system.
        static func resolved() -> (style: BackgroundStyle, strength: GlassStrength) {
            let raw = UserDefaults.standard.string(forKey: SwitcherPanel.backgroundDefaultsKey) ?? "solid"
            let stored = BackgroundStyle(rawValue: raw) ?? .solid
            switch stored {
            case .system:
                if #available(macOS 26.0, *) { return (.glass, GlassStrength.defaultLevel) }
                return (.transparent, GlassStrength.defaultLevel)
            case .glass:
                guard #available(macOS 26.0, *) else { return (.solid, SwitcherPanel.currentGlassStrength()) }
                return (.glass, SwitcherPanel.currentGlassStrength())
            case .solid, .transparent:
                return (stored, SwitcherPanel.currentGlassStrength())
            }
        }
    }

    private var installedStyle: BackgroundStyle?
    private var installedGlassStrength: GlassStrength?

    /// Cell geometry comes from the Style preference, re-read on every show();
    /// Icons metrics also depend on the item count and the screen width.
    private var style: SwitcherStyle = SwitcherStyle.defaultStyle
    private var metrics = SwitcherStyle.defaultStyle.metrics(count: 0, availableWidth: 0)
    private let panelPadding: CGFloat = 20
    /// Fraction of the screen width the panel may occupy.
    private let maxPanelWidthFraction: CGFloat = 0.85

    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var stackHeightConstraint: NSLayoutConstraint!
    /// Scroll view's bottom inset: panel padding plus the caption row.
    private var scrollBottomConstraint: NSLayoutConstraint?
    /// Icons style: the selected item's caption, floating under its icon at
    /// panel level (frame-positioned, clamped to the panel) so a long name
    /// is never truncated to the 120pt cell like the native switcher.
    private let captionLabel = NSTextField(labelWithString: "")
    private var captions: [String] = []
    private var thumbnailViews: [ThumbnailView] = []
    private var windowIDs: [CGWindowID] = []
    private var selectedIndex: Int = 0

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        self.level = .floating
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = false

        setupUI()
    }

    convenience init() {
        self.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    }

    // MARK: - UI Setup

    private func setupUI() {
        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = metrics.itemSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        stackHeightConstraint = stackView.heightAnchor.constraint(equalToConstant: metrics.itemHeight)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackHeightConstraint,
        ])

        captionLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        captionLabel.textColor = .labelColor
        captionLabel.alignment = .center
        captionLabel.lineBreakMode = .byTruncatingMiddle
        captionLabel.maximumNumberOfLines = 1
        captionLabel.isHidden = true

        let background = BackgroundStyle.resolved()
        installBackground(background.style, glassStrength: background.strength)
    }

    /// The opaque, appearance-adaptive plate whose label contrast the
    /// WCAGContrastTests guarantee (>= 4.5:1, WCAG AA). Also the fallback
    /// for unavailable styles.
    private static func makeSolidBackground() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.fillColor = .windowBackgroundColor
        box.borderWidth = 0
        box.cornerRadius = 16
        box.contentViewMargins = .zero
        return box
    }

    /// The glass view's content host, which doubles as the strength plate: a
    /// translucent window-background fill over the glass tones the effect down
    /// (Light / Medium); with alpha 0 (High / Max) it is a plain transparent
    /// view. The fill is a dynamic color so it re-resolves on Light/Dark
    /// changes — withAlphaComponent() on the catalog color directly would
    /// freeze whichever appearance is current at creation time.
    private static func makeGlassHost(plateAlpha: CGFloat) -> NSView {
        guard plateAlpha > 0 else {
            let host = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            return host
        }
        let plate = NSBox()
        plate.boxType = .custom
        plate.titlePosition = .noTitle
        plate.fillColor = NSColor(name: nil) { appearance in
            var color = NSColor.windowBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                color = NSColor.windowBackgroundColor.withAlphaComponent(plateAlpha)
            }
            return color
        }
        plate.borderWidth = 0
        plate.cornerRadius = 16
        plate.contentViewMargins = .zero
        plate.translatesAutoresizingMaskIntoConstraints = false
        return plate
    }

    /// Re-installs the background root only when a preference changed.
    private func installBackgroundIfNeeded() {
        let (style, strength) = BackgroundStyle.resolved()
        if style != installedStyle || (style == .glass && strength != installedGlassStrength) {
            installBackground(style, glassStrength: strength)
        }
    }

    /// Builds the root view for the style and re-parents the persistent
    /// scroll view into it with the standard panel padding.
    private func installBackground(_ style: BackgroundStyle, glassStrength: GlassStrength) {
        scrollView.removeFromSuperview()
        captionLabel.removeFromSuperview()

        let root: NSView
        let scrollHost: NSView

        switch style {
        case .solid, .system:
            // .system is unreachable: resolved() always maps it to a drawable
            // style. Kept for exhaustiveness.
            let box = Self.makeSolidBackground()
            root = box
            scrollHost = box

        case .transparent:
            // The classic translucent HUD (pre-1.2 look). Labels are
            // effect-view descendants, so they render with vibrancy; the
            // material is appearance-adaptive and auto-opaques when
            // "Reduce transparency" (Accessibility) is enabled.
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 16
            effect.layer?.masksToBounds = true
            root = effect
            scrollHost = effect

        case .glass:
            if #available(macOS 26.0, *) {
                // NSGlassEffectView only guarantees placement of content
                // assigned to contentView (SDK header contract), so the
                // scroll view lives in an embedded host view. As of
                // macOS 26.5, assigning contentView also auto-pins it
                // edge-to-edge internally; the explicit constraints below are
                // deliberate agreeing duplicates of that undocumented
                // behavior — re-examine on major OS updates.
                // No intensity API exists, so the strength preference maps onto
                // the two knobs there are: the clear style for Max, and the
                // host's translucent plate for Light / Medium (see GlassStrength).
                let glass = NSGlassEffectView()
                glass.cornerRadius = 16
                glass.style = glassStrength.usesClearStyle ? .clear : .regular
                let host = Self.makeGlassHost(plateAlpha: glassStrength.plateAlpha)
                glass.contentView = host
                NSLayoutConstraint.activate([
                    host.topAnchor.constraint(equalTo: glass.topAnchor),
                    host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
                    host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                ])
                root = glass
                scrollHost = host
            } else {
                // Unreachable: BackgroundStyle.current() never yields .glass
                // below macOS 26. Kept for exhaustiveness.
                let box = Self.makeSolidBackground()
                root = box
                scrollHost = box
            }
        }

        contentView = root
        scrollHost.addSubview(scrollView)
        scrollHost.addSubview(captionLabel)
        let bottom = scrollView.bottomAnchor.constraint(equalTo: scrollHost.bottomAnchor,
                                                        constant: -(panelPadding + self.style.captionRowHeight))
        scrollBottomConstraint = bottom
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: scrollHost.topAnchor, constant: panelPadding),
            bottom,
            scrollView.leadingAnchor.constraint(equalTo: scrollHost.leadingAnchor, constant: panelPadding),
            scrollView.trailingAnchor.constraint(equalTo: scrollHost.trailingAnchor, constant: -panelPadding),
        ])
        installedStyle = style
        installedGlassStrength = glassStrength
    }

    // MARK: - Public API

    func show(windows: [WindowInfo], selectedIndex: Int) {
        applyAppearancePreference()
        installBackgroundIfNeeded()
        // The panel opens on the screen containing the mouse; its width caps
        // the strip, which is what Icons metrics adapt to.
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let maxPanelWidth = screen.frame.width * maxPanelWidthFraction
        applyStylePreference(count: windows.count, availableWidth: maxPanelWidth - panelPadding * 2)
        self.selectedIndex = selectedIndex

        // Clear old
        thumbnailViews.forEach { $0.removeFromSuperview() }
        thumbnailViews.removeAll()
        windowIDs = windows.map { $0.windowID }
        let grouped = UserDefaults.standard.bool(forKey: AppGrouping.defaultsKey)
        captions = windows.map {
            SwitcherStyle.caption(windowTitle: $0.windowTitle, appName: $0.ownerName, grouped: grouped)
        }

        // Build new
        for (index, windowInfo) in windows.enumerated() {
            let view = ThumbnailView(windowInfo: windowInfo, style: style, metrics: metrics)
            view.onClicked = { [weak self] in
                self?.handleClick(index: index)
            }
            // Join the hierarchy before setting selection: isSelected resolves
            // and freezes CGColors via effectiveAppearance, which only reflects
            // the panel's forced appearance once the view is parented.
            stackView.addArrangedSubview(view)
            thumbnailViews.append(view)
            view.isSelected = (index == selectedIndex)
        }

        // Size and position the panel.
        let contentWidth = metrics.stripWidth(count: windows.count)
        let panelWidth = min(maxPanelWidth, contentWidth + panelPadding * 2)
        let panelHeight = metrics.itemHeight + style.captionRowHeight + panelPadding * 2

        let panelX = screen.frame.midX - panelWidth / 2
        let panelY = screen.frame.midY - panelHeight / 2

        setFrame(NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight), display: true)

        orderFrontRegardless()
        scrollToSelected()
        positionCaption()
    }

    func updateSelection(index: Int) {
        guard index >= 0, index < thumbnailViews.count else { return }
        if selectedIndex < thumbnailViews.count {
            thumbnailViews[selectedIndex].isSelected = false
        }
        selectedIndex = index
        thumbnailViews[selectedIndex].isSelected = true
        scrollToSelected()
        positionCaption()
    }

    /// Patches a captured preview into its cell without rebuilding the panel.
    func updateThumbnail(windowID: CGWindowID, image: NSImage) {
        guard let index = windowIDs.firstIndex(of: windowID),
              index < thumbnailViews.count else { return }
        thumbnailViews[index].setThumbnail(image)
    }

    func dismiss() {
        orderOut(nil)
        thumbnailViews.forEach { $0.removeFromSuperview() }
        thumbnailViews.removeAll()
        windowIDs.removeAll()
        captions.removeAll()
        captionLabel.isHidden = true
    }

    // MARK: - Private

    /// Re-reads the Style preference, computes the cell metrics for this
    /// invocation, and resizes the strip for them.
    private func applyStylePreference(count: Int, availableWidth: CGFloat) {
        style = SwitcherStyle.resolve(UserDefaults.standard.string(forKey: SwitcherStyle.defaultsKey))
        metrics = style.metrics(count: count, availableWidth: availableWidth)
        stackView.spacing = metrics.itemSpacing
        stackHeightConstraint.constant = metrics.itemHeight
        scrollBottomConstraint?.constant = -(panelPadding + style.captionRowHeight)
    }

    /// Icons style: lays the selected item's caption out in the caption row,
    /// centered under its icon and clamped inside the panel padding. Sized to
    /// the text, so it spans neighbouring cells rather than truncating; only
    /// a name wider than the whole panel is (middle-)truncated.
    private func positionCaption() {
        guard style.captionRowHeight > 0, selectedIndex < thumbnailViews.count,
              selectedIndex < captions.count, let host = captionLabel.superview else {
            captionLabel.isHidden = true
            return
        }
        captionLabel.stringValue = captions[selectedIndex]
        captionLabel.isHidden = false
        captionLabel.sizeToFit()
        host.layoutSubtreeIfNeeded()

        let cell = thumbnailViews[selectedIndex]
        let cellInHost = cell.convert(cell.bounds, to: host)
        let maxWidth = max(0, host.bounds.width - panelPadding * 2)
        let size = NSSize(width: min(captionLabel.frame.width, maxWidth), height: captionLabel.frame.height)
        let minX = panelPadding
        let maxX = host.bounds.width - panelPadding - size.width
        let x = min(max(cellInHost.midX - size.width / 2, minX), maxX)
        let y = panelPadding + (style.captionRowHeight - size.height) / 2
        captionLabel.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Applies the user's appearance preference; nil follows the OS theme.
    private func applyAppearancePreference() {
        switch UserDefaults.standard.string(forKey: Self.appearanceDefaultsKey) {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark": appearance = NSAppearance(named: .darkAqua)
        default: appearance = nil
        }
    }

    private func scrollToSelected() {
        guard selectedIndex < thumbnailViews.count else { return }
        let view = thumbnailViews[selectedIndex]
        scrollView.contentView.scrollToVisible(view.frame)
    }

    private func handleClick(index: Int) {
        updateSelection(index: index)
        onWindowClicked?(index)
    }

    // Allow mouse interaction even though we're non-activating
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
