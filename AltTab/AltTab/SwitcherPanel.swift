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
        /// Liquid Glass at the OS default (`followsSystem`: the view's style
        /// and tint are left untouched, so Appearance/Accessibility settings
        /// and any future default apply as-is) on 26+, the translucent HUD
        /// material before — so it never returns .system.
        static func resolved() -> (style: BackgroundStyle, strength: GlassStrength, followsSystem: Bool) {
            let raw = UserDefaults.standard.string(forKey: SwitcherPanel.backgroundDefaultsKey) ?? "solid"
            let stored = BackgroundStyle(rawValue: raw) ?? .solid
            switch stored {
            case .system:
                if #available(macOS 26.0, *) { return (.glass, GlassStrength.defaultLevel, true) }
                return (.transparent, GlassStrength.defaultLevel, true)
            case .glass:
                guard #available(macOS 26.0, *) else { return (.solid, SwitcherPanel.currentGlassStrength(), false) }
                return (.glass, SwitcherPanel.currentGlassStrength(), false)
            case .solid, .transparent:
                return (stored, SwitcherPanel.currentGlassStrength(), false)
            }
        }
    }

    private var installedStyle: BackgroundStyle?
    private var installedGlassStrength: GlassStrength?
    private var installedFollowsSystem: Bool?
    private var installedCornerRadius: CGFloat?

    /// Cell geometry comes from the Style preference, re-read on every show();
    /// Icons metrics also depend on the item count and the screen width.
    private var style: SwitcherStyle = SwitcherStyle.defaultStyle
    private var metrics = SwitcherStyle.defaultStyle.metrics(count: 0, maxPanelWidth: 0)

    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var stackHeightConstraint: NSLayoutConstraint!
    /// Scroll view insets from the background root: the panel padding, plus
    /// the caption row at the bottom. Re-tuned per style on every show().
    private var scrollTopConstraint: NSLayoutConstraint?
    private var scrollBottomConstraint: NSLayoutConstraint?
    private var scrollLeadingConstraint: NSLayoutConstraint?
    private var scrollTrailingConstraint: NSLayoutConstraint?
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

        captionLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        captionLabel.textColor = .labelColor
        captionLabel.alignment = .center
        captionLabel.lineBreakMode = .byTruncatingMiddle
        captionLabel.maximumNumberOfLines = 1
        captionLabel.isHidden = true

        let background = BackgroundStyle.resolved()
        installBackground(background.style, glassStrength: background.strength,
                          followsSystem: background.followsSystem, cornerRadius: metrics.panelCornerRadius)
    }

    /// The opaque, appearance-adaptive plate whose label contrast the
    /// WCAGContrastTests guarantee (>= 4.5:1, WCAG AA). Also the fallback
    /// for unavailable styles.
    private static func makeSolidBackground(cornerRadius: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.fillColor = .windowBackgroundColor
        box.borderWidth = 0
        box.cornerRadius = cornerRadius
        box.contentViewMargins = .zero
        return box
    }

    /// The glass view's content host, which doubles as the strength plate: a
    /// translucent window-background fill over the glass tones the effect down
    /// (Light / Medium); with alpha 0 (High / Max) it is a plain transparent
    /// view. The fill is a dynamic color so it re-resolves on Light/Dark
    /// changes — withAlphaComponent() on the catalog color directly would
    /// freeze whichever appearance is current at creation time.
    private static func makeGlassHost(plateAlpha: CGFloat, cornerRadius: CGFloat) -> NSView {
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
        plate.cornerRadius = cornerRadius
        plate.contentViewMargins = .zero
        plate.translatesAutoresizingMaskIntoConstraints = false
        return plate
    }

    /// Re-installs the background root only when a preference changed.
    private func installBackgroundIfNeeded() {
        let (style, strength, followsSystem) = BackgroundStyle.resolved()
        let radius = metrics.panelCornerRadius
        if style != installedStyle || (style == .glass && strength != installedGlassStrength)
            || followsSystem != installedFollowsSystem || radius != installedCornerRadius {
            installBackground(style, glassStrength: strength, followsSystem: followsSystem, cornerRadius: radius)
        }
    }

    /// Builds the root view for the style and re-parents the persistent
    /// scroll view into it with the standard panel padding.
    private func installBackground(_ style: BackgroundStyle, glassStrength: GlassStrength,
                                   followsSystem: Bool, cornerRadius: CGFloat) {
        scrollView.removeFromSuperview()
        captionLabel.removeFromSuperview()

        let root: NSView
        let scrollHost: NSView

        switch style {
        case .solid, .system:
            // .system is unreachable: resolved() always maps it to a drawable
            // style. Kept for exhaustiveness.
            let box = Self.makeSolidBackground(cornerRadius: cornerRadius)
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
            effect.layer?.cornerRadius = cornerRadius
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
                glass.cornerRadius = cornerRadius
                // Background: System leaves the style at the OS default so the
                // user's Appearance / Accessibility glass settings, and any
                // future default, apply unmodified.
                if !followsSystem {
                    glass.style = glassStrength.usesClearStyle ? .clear : .regular
                }
                let host = Self.makeGlassHost(plateAlpha: glassStrength.plateAlpha, cornerRadius: cornerRadius)
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
                // Unreachable: BackgroundStyle.resolved() never yields .glass
                // below macOS 26. Kept for exhaustiveness.
                let box = Self.makeSolidBackground(cornerRadius: cornerRadius)
                root = box
                scrollHost = box
            }
        }

        contentView = root
        scrollHost.addSubview(scrollView)
        scrollHost.addSubview(captionLabel)
        let top = scrollView.topAnchor.constraint(equalTo: scrollHost.topAnchor, constant: 0)
        let bottom = scrollView.bottomAnchor.constraint(equalTo: scrollHost.bottomAnchor, constant: 0)
        let leading = scrollView.leadingAnchor.constraint(equalTo: scrollHost.leadingAnchor, constant: 0)
        let trailing = scrollView.trailingAnchor.constraint(equalTo: scrollHost.trailingAnchor, constant: 0)
        scrollTopConstraint = top
        scrollBottomConstraint = bottom
        scrollLeadingConstraint = leading
        scrollTrailingConstraint = trailing
        NSLayoutConstraint.activate([top, bottom, leading, trailing])
        applyScrollInsets()
        installedStyle = style
        installedGlassStrength = glassStrength
        installedFollowsSystem = followsSystem
        installedCornerRadius = cornerRadius
    }

    /// Insets the strip by the current metrics' padding (plus the caption row).
    private func applyScrollInsets() {
        scrollTopConstraint?.constant = metrics.panelPaddingY
        scrollBottomConstraint?.constant = -(metrics.panelPaddingBottom + metrics.captionRowHeight)
        scrollLeadingConstraint?.constant = metrics.panelPaddingX
        scrollTrailingConstraint?.constant = -metrics.panelPaddingX
    }

    // MARK: - Public API

    func show(windows: [WindowInfo], selectedIndex: Int) {
        applyAppearancePreference()
        // The panel opens on the screen containing the mouse; its width caps
        // the strip, which is what Icons metrics adapt to. Metrics first: the
        // background's corner radius and the strip insets depend on them.
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        style = SwitcherStyle.resolve(UserDefaults.standard.string(forKey: SwitcherStyle.defaultsKey))
        let maxPanelWidth = screen.frame.width * style.maxPanelWidthFraction
        applyStylePreference(count: windows.count, maxPanelWidth: maxPanelWidth)
        installBackgroundIfNeeded()
        self.selectedIndex = selectedIndex

        // Clear old
        thumbnailViews.forEach { $0.removeFromSuperview() }
        thumbnailViews.removeAll()
        windowIDs = windows.map { $0.windowID }
        let grouped = UserDefaults.standard.bool(forKey: AppGrouping.defaultsKey)
        captions = windows.map {
            // ownerName is the window server's process name ("Code"); the
            // native switcher shows the app's localized display name
            // ("Visual Studio Code"). Cheap main-thread lookup, no IPC.
            let appName = NSRunningApplication(processIdentifier: $0.ownerPID)?.localizedName ?? $0.ownerName
            return SwitcherStyle.caption(windowTitle: $0.windowTitle, appName: appName, grouped: grouped)
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
        let panelWidth = min(maxPanelWidth, metrics.panelWidth(count: windows.count))
        let panelHeight = metrics.panelHeight

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

    /// Computes the cell metrics for this invocation (style already resolved
    /// by show()) and resizes the strip for them.
    private func applyStylePreference(count: Int, maxPanelWidth: CGFloat) {
        metrics = style.metrics(count: count, maxPanelWidth: maxPanelWidth)
        stackView.spacing = metrics.itemSpacing
        stackHeightConstraint.constant = metrics.itemHeight
        applyScrollInsets()
    }

    /// Icons style: lays the selected item's caption out in the caption row,
    /// centered under its icon and clamped inside the panel padding. Sized to
    /// the text, so it spans neighbouring cells rather than truncating; only
    /// a name wider than the whole panel is (middle-)truncated.
    private func positionCaption() {
        guard metrics.captionRowHeight > 0, selectedIndex < thumbnailViews.count,
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
        let padX = metrics.panelPaddingX
        let maxWidth = max(0, host.bounds.width - padX * 2)
        let size = NSSize(width: min(captionLabel.frame.width, maxWidth), height: captionLabel.frame.height)
        let minX = padX
        let maxX = host.bounds.width - padX - size.width
        let x = min(max(cellInHost.midX - size.width / 2, minX), maxX)
        // The text sits at the bottom of the caption row, i.e. captionGapScale
        // of an icon under the artwork, with panelPaddingBottom beneath it.
        let y = metrics.panelPaddingBottom
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
