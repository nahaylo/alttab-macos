//
//  WindowModel.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Window discovery and MRU (most recently used) tracking. Discovers on-screen
//  windows via CGWindowListCopyWindowInfo, then makes a single Accessibility
//  pass per application that fills in titles (kCGWindowName needs Screen
//  Recording; AX titles only need Accessibility) and finds windows the CG
//  list can't see: minimized, ⌘H-hidden apps, and other Spaces. Every AX call
//  is bounded by a messaging timeout so one wedged app can't stall the
//  switcher (the AX default is ~6 seconds per call).
//
//  Enumeration is split so the switcher opens instantly: windowsFromCache()
//  serves the last gathered list re-sorted by current MRU on the main thread,
//  while refreshWindows() gathers a fresh list off the main thread (apps
//  visited concurrently; apps that fail the AX pass keep their previously
//  cached windows) and reconciles on completion. Focus and app-lifecycle
//  events also schedule a debounced background refresh, so the cache stays
//  warm between invocations instead of freezing at the last switcher session.
//  MRU order is maintained by NSWorkspace activation notifications and
//  per-app AXObservers that track intra-app focused-window changes (e.g.
//  Cmd-` between two Terminal windows). Uses the private
//  _AXUIElementGetWindow SPI to bridge AXUIElement to CGWindowID — the
//  standard approach for macOS window managers.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  Version: 1.2.0
//  Date:    2026-07-01
//  License: MIT
//

import Cocoa
import ApplicationServices

// MARK: - WindowInfo

struct WindowInfo {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    var windowTitle: String
    let bounds: CGRect
    let isMinimized: Bool
    var thumbnail: NSImage?

    /// Returns the app icon for this window's owner process, served from an in-memory
    /// cache so the switcher never hits LaunchServices/disk while building the panel.
    var appIcon: NSImage {
        AppIconCache.shared.icon(forPID: ownerPID)
    }
}

// MARK: - AppIconCache

/// Caches application icons by PID. `NSRunningApplication.icon` resolves a LaunchServices
/// binding and reads the icon file from disk on every access; doing that per cell on every
/// activation is what made the panel render before its icons appeared (profiled via
/// `sample`: ~6% of main-thread work plus synchronous `open()` calls). NSCache is
/// thread-safe, so main-thread reads and prewarming coexist safely.
final class AppIconCache {
    static let shared = AppIconCache()

    private let cache = NSCache<NSNumber, NSImage>()
    private let fallback = NSImage(named: NSImage.applicationIconName)!
    /// Icon resolution touches LaunchServices and disk; prewarms run here so
    /// they never contend with the run loop that services the event tap.
    /// NSRunningApplication and NSCache are both documented thread-safe.
    private let resolveQueue = DispatchQueue(label: "com.alttab.icon-prewarm", qos: .utility)

    /// Returns a cached icon, resolving and caching it on first request.
    func icon(forPID pid: pid_t) -> NSImage {
        let key = NSNumber(value: pid)
        if let hit = cache.object(forKey: key) { return hit }
        let resolved = NSRunningApplication(processIdentifier: pid)?.icon ?? fallback
        cache.setObject(resolved, forKey: key)
        return resolved
    }

    /// Resolve and cache an icon ahead of time so the first switch is already
    /// warm. Resolution happens on the internal utility queue; callers return
    /// immediately.
    func prewarm(pid: pid_t) {
        let key = NSNumber(value: pid)
        guard cache.object(forKey: key) == nil else { return }
        resolveQueue.async { [self] in
            guard cache.object(forKey: key) == nil else { return }
            if let resolved = NSRunningApplication(processIdentifier: pid)?.icon {
                cache.setObject(resolved, forKey: key)
            }
        }
    }

    /// Drop an icon when its app quits so a recycled PID can't surface a stale
    /// icon. Routed through resolveQueue so an evict enqueued after an
    /// in-flight prewarm for the same PID always lands after it — otherwise
    /// the prewarm could re-cache the dead app's icon post-evict.
    func evict(pid: pid_t) {
        let key = NSNumber(value: pid)
        resolveQueue.async { [self] in
            cache.removeObject(forKey: key)
        }
    }
}

// MARK: - WindowModel

/// All state (MRU order, cache, pending activation, observers) is confined to the
/// main thread; only the stateless gather step runs on the background queue.
final class WindowModel {

    private var mru = MRUOrder()
    private var cachedWindows: [WindowInfo] = []
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    /// Explicit activation in flight: the didActivateApplication notification for
    /// this PID must promote this window, not whatever kAXFocusedWindow returns
    /// while the off-main AX raise is still landing.
    private var pendingActivation: (pid: pid_t, windowID: CGWindowID, at: Date)?
    private static let pendingActivationWindow: TimeInterval = 2.0

    /// Upper bound (seconds) on a single AX message. Timeouts are per-element,
    /// so it must be applied to both app and window elements.
    private static let axMessagingTimeout: Float = 0.25

    private let gatherQueue = DispatchQueue(label: "com.alttab.window-gather", qos: .userInitiated)

    /// Serial queue for the synchronous kAXFocusedWindow probe on app
    /// activation — off the main thread so an unresponsive app can't stall
    /// the run loop that services the event tap; serial so rapid activations
    /// resolve in order.
    private let focusProbeQueue = DispatchQueue(label: "com.alttab.focus-probe", qos: .userInitiated)

    /// Per-PID AXObservers for intra-app window focus tracking.
    private var axObservers: [pid_t: AXObserver] = [:]

    /// Main-thread-confined focus-signal counter, bumped whenever a newer
    /// focus truth is recorded (explicit switch, app activation, intra-app
    /// focus change). The async focused-window probe captures the epoch at
    /// dispatch; its main-hop promote is dropped once the epoch has advanced,
    /// so a late AX read can never overwrite newer focus knowledge.
    private var focusEpoch = 0

    /// Keeps the cache warm: every focus/lifecycle event schedules a
    /// debounced background gather, so the first Option-Tab after idle serves
    /// a list gathered shortly after the last focus change instead of one
    /// frozen at the previous switcher session. Bursts (app activation fires
    /// both a workspace notification and an AXObserver event) coalesce into
    /// one gather, and a rate floor caps background sweeps to one per
    /// `backgroundRefreshMinSpacing` under sustained switching — the fire is
    /// pushed back, never dropped, so the trailing gather still happens.
    /// Main-thread confined, like the rest of the model's state.
    private static let backgroundRefreshDebounce: TimeInterval = 1.0
    private static let backgroundRefreshMinSpacing: TimeInterval = 8.0
    private var lastGatherFinished = Date.distantPast

    private lazy var refreshDebouncer = Debouncer(interval: Self.backgroundRefreshDebounce) { [weak self] in
        self?.debouncedRefreshFired()
    }

    /// Schedules the debounced cache refresh (main thread only).
    private func scheduleCacheRefresh() {
        refreshDebouncer.schedule()
    }

    private func debouncedRefreshFired() {
        let sinceLast = Date().timeIntervalSince(lastGatherFinished)
        if sinceLast < Self.backgroundRefreshMinSpacing {
            // Clamp the re-arm: a backward wall-clock step makes sinceLast
            // negative, and an unclamped remainder would suppress background
            // refreshes for the entire jump duration.
            let remaining = min(Self.backgroundRefreshMinSpacing - sinceLast, Self.backgroundRefreshMinSpacing)
            refreshDebouncer.schedule(after: remaining)
        } else {
            refreshWindows(coalescible: true) { _ in }
        }
    }

    /// Monotonic gather-request counter, bumped on main per refresh request
    /// and read on gatherQueue: a queued COALESCIBLE (background) sweep that
    /// has been superseded by a newer request skips its AX work entirely, so
    /// a backlog behind a wedged app can never delay the newest request —
    /// in particular the switcher-activation refresh that drives reconcile
    /// and previews, which is never coalescible.
    private final class GatherGeneration {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
        var current: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
    private let gatherGeneration = GatherGeneration()

    init() {
        seedMRUFromStackingOrder()
        observeAppActivation()
        observeAppLifecycle()
        installAXObserversForRunningApps()
        prewarmIcons()
        refreshWindows { _ in } // warm the cache so the first Option-Tab is instant
    }

    deinit {
        removeAllAXObservers()
    }

    // MARK: - Enumeration API (main thread)

    /// Best-effort ID of the window that actually has user focus right now.
    /// Returns nil when it cannot tell — callers fall back to the classic
    /// slot-1 anchor. Resolution order:
    /// 1. A fresh pendingActivation: an explicit switch is still landing, so
    ///    probing would report the window being switched AWAY from and a
    ///    rapid re-invoke would anchor on the wrong slot.
    /// 2. The frontmost app's topmost on-screen layer-0 window (one cheap
    ///    WindowServer query) when the cache knows that window.
    /// 3. When it doesn't — either a brand-new focused window (true previous
    ///    is slot 0) or a sheet/child above its listed parent (true previous
    ///    is slot 1) — ask the app which window is focused: one AX round trip
    ///    bounded by the standard timeout, on this rare branch only.
    func frontmostWindowID() -> CGWindowID? {
        if let pending = pendingActivation,
           Date().timeIntervalSince(pending.at) < Self.pendingActivationWindow {
            return pending.windowID
        }
        guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontPID != selfPID else { return nil }

        let cgTopmost = topmostOnScreenWindowID(ownedBy: frontPID)
        if let id = cgTopmost, cachedWindows.contains(where: { $0.windowID == id }) {
            return id
        }

        let axApp = AXUIElementCreateApplication(frontPID)
        AXUIElementSetMessagingTimeout(axApp, Self.axMessagingTimeout)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let focusedWindow = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(focusedWindow, Self.axMessagingTimeout)
            var windowID: CGWindowID = 0
            _ = _AXUIElementGetWindow(focusedWindow, &windowID)
            if windowID != 0 { return windowID }
        }
        return cgTopmost
    }

    private func topmostOnScreenWindowID(ownedBy pid: pid_t) -> CGWindowID? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 0, h > 0 else { continue }
            return id
        }
        return nil
    }

    /// Returns the last gathered window list re-sorted by current MRU. On the
    /// cold path (first invoke before the init warm-up lands) it serves the
    /// on-screen list from one cheap WindowServer query — a synchronous AX
    /// gather here would run on the run loop that services the event tap and
    /// can get the tap disabled by timeout. Titles and off-screen windows
    /// arrive with the async refresh; MRU is deliberately not synced against
    /// the partial list so it can't prune ranks. Follow with refreshWindows()
    /// to reconcile against reality.
    func windowsFromCache() -> [WindowInfo] {
        if cachedWindows.isEmpty {
            cachedWindows = Self.onScreenWindows(selfPID: selfPID)
        }
        return mru.sorted(cachedWindows) { $0.windowID }
    }

    /// Gathers a fresh window list off the main thread, then caches, sorts, and
    /// completes on the main thread. Apps that failed the AX pass (wedged,
    /// App-Napped) said nothing about their windows: those are carried over
    /// from the previous cache so one 0.25s timeout can't drop them from the
    /// panel or erase their MRU ranks.
    func refreshWindows(coalescible: Bool = false, completion: @escaping ([WindowInfo]) -> Void) {
        let apps = Self.regularAppsSnapshot() // NSWorkspace snapshot taken on main
        let selfPID = self.selfPID
        let generation = gatherGeneration.next()
        let generationBox = gatherGeneration
        // Weak at the OUTER closure: the gather must not keep the model alive, and
        // an inner-only [weak self] would make this closure capture self strongly
        // just to hand it over. `WindowModel.` rather than `Self.` for the same
        // reason — in a class body `Self` is the dynamic type, i.e. a self capture.
        gatherQueue.async { [weak self] in
            // A background sweep that a newer request has already superseded
            // would only produce data the next gather immediately replaces —
            // skip it so the newest request starts sooner. Never skipped for
            // activation refreshes: their completion drives the session.
            if coalescible && generation != generationBox.current { return }
            let result = WindowModel.gatherWindows(regularApps: apps, selfPID: selfPID)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lastGatherFinished = Date()
                let merged = GatherMerge.merge(previous: self.cachedWindows,
                                               gathered: result.windows,
                                               unresponsivePIDs: result.unresponsivePIDs,
                                               id: { $0.windowID },
                                               ownerPID: { $0.ownerPID })
                self.cachedWindows = merged
                self.mru.sync(windows: merged.map { (id: $0.windowID, pid: $0.ownerPID) })
                completion(self.mru.sorted(merged) { $0.windowID })
            }
        }
    }

    // MARK: - Gathering (stateless, any thread)

    private struct AppRef {
        let pid: pid_t
        let name: String
    }

    private struct GatherResult {
        let windows: [WindowInfo]
        /// PIDs whose AX window-list query failed as unresponsive — their
        /// off-screen windows are missing from `windows` and must be carried
        /// over from the previous cache rather than treated as closed.
        let unresponsivePIDs: Set<pid_t>
    }

    /// Per-app outcome of the concurrent AX pass, merged sequentially after.
    private struct AppAXResult {
        var titles: [(CGWindowID, String)] = []
        var discovered: [WindowInfo] = []
        var unresponsive = false
    }

    private static func regularAppsSnapshot() -> [AppRef] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { AppRef(pid: $0.processIdentifier, name: $0.localizedName ?? "Unknown") }
    }

    /// On-screen windows (any app, current Space) from one WindowServer query
    /// — no AX IPC, safe on the main thread (cold cache path).
    private static func onScreenWindows(selfPID: pid_t) -> [WindowInfo] {
        var windows: [WindowInfo] = []
        var seenIDs = Set<CGWindowID>()
        if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] {
            for info in infoList {
                guard let window = parseWindowInfo(info) else { continue }
                guard window.ownerPID != selfPID, !seenIDs.contains(window.windowID) else { continue }
                seenIDs.insert(window.windowID)
                windows.append(window)
            }
        }
        return windows
    }

    private static func gatherWindows(regularApps: [AppRef], selfPID: pid_t) -> GatherResult {
        // 1. On-screen windows from CGWindowList.
        var windows = onScreenWindows(selfPID: selfPID)
        let onScreenIDs = Set(windows.map { $0.windowID })
        var needsTitle: [CGWindowID: Int] = [:] // windowID → index into windows
        for (index, window) in windows.enumerated() where window.windowTitle.isEmpty {
            needsTitle[window.windowID] = index
        }

        // 2. One AX pass per app: titles for on-screen windows, plus discovery
        //    of minimized, hidden-app, and other-Space windows. Covers regular
        //    apps and any non-regular app that owns an on-screen window. Apps
        //    are queried CONCURRENTLY: the pass is dominated by mach_msg waits
        //    (up to 0.25s per call against a wedged app), so sequential visits
        //    stack those waits into seconds. Each iteration writes only its own
        //    slot; the merge below runs sequentially in sorted-pid order, which
        //    also keeps discovery order deterministic across gathers.
        let regularPIDs = Set(regularApps.map { $0.pid })
        var appNames = Dictionary(regularApps.map { ($0.pid, $0.name) },
                                  uniquingKeysWith: { first, _ in first })
        for window in windows where appNames[window.ownerPID] == nil {
            appNames[window.ownerPID] = window.ownerName
        }
        let axPIDs = regularPIDs.union(windows.map { $0.ownerPID })
            .subtracting([selfPID])
            .sorted()
        let names = axPIDs.map { appNames[$0] ?? "Unknown" }
        let needsTitleIDs = Set(needsTitle.keys)

        var results = [AppAXResult?](repeating: nil, count: axPIDs.count)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: axPIDs.count) { i in
                buffer[i] = axPass(pid: axPIDs[i],
                                   appName: names[i],
                                   needsTitleIDs: needsTitleIDs,
                                   onScreenIDs: onScreenIDs,
                                   discoverOffScreen: regularPIDs.contains(axPIDs[i]))
            }
        }

        var unresponsivePIDs = Set<pid_t>()
        for (i, result) in results.enumerated() {
            guard let result = result else { continue }
            if result.unresponsive { unresponsivePIDs.insert(axPIDs[i]) }
            for (windowID, title) in result.titles {
                if let index = needsTitle[windowID] {
                    windows[index].windowTitle = title
                    needsTitle[windowID] = nil
                }
            }
            windows.append(contentsOf: result.discovered)
        }
        return GatherResult(windows: windows, unresponsivePIDs: unresponsivePIDs)
    }

    /// The AX visit for a single app: fills titles for its on-screen windows
    /// and discovers its off-screen (minimized, ⌘H-hidden, other-Space) ones.
    /// Pure with respect to shared state — safe to run concurrently per app.
    private static func axPass(pid: pid_t, appName: String, needsTitleIDs: Set<CGWindowID>,
                               onScreenIDs: Set<CGWindowID>, discoverOffScreen: Bool) -> AppAXResult {
        var result = AppAXResult()
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, axMessagingTimeout)
        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard err == .success, let axWindows = windowsRef as? [AXUIElement] else {
            result.unresponsive = didNotAnswer(err)
            return result
        }

        var discoveredIDs = Set<CGWindowID>()
        for axWindow in axWindows {
            AXUIElementSetMessagingTimeout(axWindow, axMessagingTimeout)
            var windowID: CGWindowID = 0
            _ = _AXUIElementGetWindow(axWindow, &windowID)
            guard windowID != 0 else { continue }

            if needsTitleIDs.contains(windowID) {
                let title = copyAttribute(axWindow, kAXTitleAttribute)
                if didNotAnswer(title.error) { result.unresponsive = true }
                if let value = title.ref as? String, !value.isEmpty {
                    result.titles.append((windowID, value))
                }
            } else if !onScreenIDs.contains(windowID), discoverOffScreen, !discoveredIDs.contains(windowID) {
                // Off-screen: minimized, ⌘H-hidden app, or another Space. An
                // app can answer kAXWindows and then wedge mid-enumeration:
                // an unanswered classification read must not silently drop
                // the window (that would bypass the carry-over and re-create
                // the rank-amnesia bug) — flag the app unresponsive and let
                // the previous cache entry, with its last known state, stand in.
                let minimized = copyAttribute(axWindow, kAXMinimizedAttribute)
                if didNotAnswer(minimized.error) {
                    result.unresponsive = true
                    continue
                }
                let isMinimized = (minimized.ref as? Bool) ?? false
                if !isMinimized {
                    let subrole = copyAttribute(axWindow, kAXSubroleAttribute)
                    if didNotAnswer(subrole.error) {
                        result.unresponsive = true
                        continue
                    }
                    // Only standard windows — skips palettes, sheets, popovers.
                    guard (subrole.ref as? String) == kAXStandardWindowSubrole as String else { continue }
                }
                discoveredIDs.insert(windowID)
                result.discovered.append(WindowInfo(
                    windowID: windowID,
                    ownerPID: pid,
                    ownerName: appName,
                    windowTitle: copyString(axWindow, kAXTitleAttribute),
                    bounds: .zero,
                    isMinimized: isMinimized,
                    thumbnail: nil
                ))
            }
        }
        return result
    }

    private static func parseWindowInfo(_ info: [String: Any]) -> WindowInfo? {
        guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
              let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
              let ownerName = info[kCGWindowOwnerName as String] as? String,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = boundsDict["X"], let y = boundsDict["Y"],
              let w = boundsDict["Width"], let h = boundsDict["Height"],
              w > 0 && h > 0 else { return nil }

        // kCGWindowName requires Screen Recording; empty titles are filled from
        // the AX pass, which only needs Accessibility.
        return WindowInfo(
            windowID: windowID,
            ownerPID: ownerPID,
            ownerName: ownerName,
            windowTitle: info[kCGWindowName as String] as? String ?? "",
            bounds: CGRect(x: x, y: y, width: w, height: h),
            isMinimized: false,
            thumbnail: nil
        )
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String {
        let result = copyAttribute(element, attribute)
        return result.ref as? String ?? ""
    }

    /// Attribute read that surfaces the AXError, so callers can distinguish
    /// "answered: absent" from "did not answer" (see didNotAnswer).
    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> (ref: CFTypeRef?, error: AXError) {
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        return (error == .success ? ref : nil, error)
    }

    /// True for AX errors meaning the app did not answer — .cannotComplete
    /// (wedged/App-Napped/timed out) or .apiDisabled (no AX trust). Absence
    /// of data then says nothing about windows being closed, so the caller
    /// must flag the app unresponsive for carry-over. Every other error
    /// (.noValue, .attributeUnsupported, .invalidUIElement for a window
    /// closed mid-pass) is an answer.
    private static func didNotAnswer(_ error: AXError) -> Bool {
        error == .cannotComplete || error == .apiDisabled
    }

    // MARK: - MRU Management (main thread)

    /// Records that the user explicitly switched to a window, so the upcoming
    /// app-activation notification can't demote it (the notification may read
    /// kAXFocusedWindow before the off-main AX raise lands).
    func noteExplicitActivation(pid: pid_t, windowID: CGWindowID) {
        focusEpoch += 1
        mru.promoteToFront(windowID, pid: pid)
        pendingActivation = (pid: pid, windowID: windowID, at: Date())
        // A same-app switch fires no didActivateApplication, and the app's
        // AXObserver may be dead — schedule the refresh here so every explicit
        // switch still re-warms the cache.
        scheduleCacheRefresh()
    }

    private func seedMRUFromStackingOrder() {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return }
        mru.seed(windows: infoList.compactMap { info -> (id: CGWindowID, pid: pid_t)? in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 0 && h > 0 else { return nil }
            return (id: id, pid: pid)
        })
    }

    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Self-heal: an observer registration that failed earlier (app was
            // busy at grant time, AX server not up at launch) succeeds here on
            // the app's first activation; installed pids return immediately.
            if app.activationPolicy == .regular {
                self?.installAXObserver(for: app.processIdentifier)
            }
            self?.promoteAppWindows(pid: app.processIdentifier)
        }
    }

    /// When an app is activated, promote its frontmost window in MRU.
    private func promoteAppWindows(pid: pid_t) {
        focusEpoch += 1
        scheduleCacheRefresh()

        if let pending = pendingActivation, pending.pid == pid {
            pendingActivation = nil
            if Date().timeIntervalSince(pending.at) < Self.pendingActivationWindow {
                mru.promoteToFront(pending.windowID, pid: pending.pid)
                return
            }
        } else if pendingActivation != nil {
            // A different app activated: the pending switch is superseded and
            // must not be consumed by a LATER activation of its app, nor keep
            // anchoring frontmostWindowID() on a window that lost focus.
            pendingActivation = nil
        }

        // The kAXFocusedWindow read is synchronous IPC bounded only by the
        // 0.25s timeout — run it off the main thread so an app activation
        // can't stall the run loop that services the event tap. The promote
        // hops back to main (MRU is main-confined) guarded by the focus
        // epoch: any newer focus signal (explicit switch, another activation,
        // an intra-app focus change) drops the late result, so a stale read
        // can never overwrite newer focus knowledge. A switcher invoked
        // inside the probe window is safe regardless: the anchor logic probes
        // actual focus and treats an unpromoted focused window as "ranked
        // elsewhere", selecting the true previous window either way.
        let epoch = focusEpoch
        focusProbeQueue.async { [weak self] in
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, Self.axMessagingTimeout)
            var focusedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
                  let focused = focusedRef,
                  CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
            let focusedWindow = focused as! AXUIElement
            var windowID: CGWindowID = 0
            _ = _AXUIElementGetWindow(focusedWindow, &windowID)
            guard windowID != 0 else { return }
            DispatchQueue.main.async {
                guard let self = self, self.focusEpoch == epoch else { return }
                self.mru.promoteToFront(windowID, pid: pid)
            }
        }
    }

    // MARK: - AXObserver (Intra-App Focus Tracking)

    /// Install AXObservers on all currently running regular apps.
    private func installAXObserversForRunningApps() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID
        }
        for app in apps {
            installAXObserver(for: app.processIdentifier)
        }
    }

    /// Warm the icon cache for currently-running apps at launch. Resolution
    /// runs on AppIconCache's utility queue (prewarm returns immediately), so
    /// startup and the event tap's run loop are never blocked; subsequent
    /// launches are warmed via the didLaunch notification in observeAppLifecycle().
    private func prewarmIcons() {
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { $0.processIdentifier }
        for pid in pids { AppIconCache.shared.prewarm(pid: pid) }
    }

    /// Creates an AXObserver for a single app and watches for focused-window
    /// changes. Registration fails when Accessibility is not yet granted
    /// (kAXErrorAPIDisabled) or the app's AX server is not up yet; failures
    /// are NOT stored, so a later reinstallAXObservers()/retry can succeed.
    @discardableResult
    private func installAXObserver(for pid: pid_t) -> Bool {
        if axObservers[pid] != nil { return true }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &observer)
        guard result == .success, let observer = observer else { return false }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.axMessagingTimeout)
        guard AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return false }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObservers[pid] = observer
        return true
    }

    /// Re-attempts observer installation for all running regular apps. Called
    /// when Accessibility becomes trusted after launch: registrations made
    /// pre-grant failed and were not stored, so intra-app focus tracking would
    /// otherwise stay silently dead until relaunch. Installed pids are skipped.
    func reinstallAXObservers() {
        installAXObserversForRunningApps()
    }

    /// Remove observer for a terminated app.
    private func removeAXObserver(for pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        let axApp = AXUIElementCreateApplication(pid)
        AXObserverRemoveNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func removeAllAXObservers() {
        for pid in axObservers.keys {
            removeAXObserver(for: pid)
        }
    }

    /// Called from the AXObserver C callback when any app's focused window
    /// changes. Only the frontmost app may promote: background apps also fire
    /// kAXFocusedWindowChanged (Electron/Chromium churn, windows closed by
    /// finished jobs), and an unguarded promote lets them silently steal MRU
    /// front while the user works elsewhere. AXUIElementGetPid reads the pid
    /// from the element token — no IPC.
    fileprivate func handleFocusedWindowChanged(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        var windowID: CGWindowID = 0
        _ = _AXUIElementGetWindow(element, &windowID)
        if windowID != 0 {
            // An intra-app switch never fires didActivateApplication, so its
            // pending record is only retired here: a newer focus observation
            // of a DIFFERENT window supersedes it (the same window confirms
            // it and must stay for the didActivate consumer).
            if let pending = pendingActivation, pending.windowID != windowID {
                pendingActivation = nil
            }
            focusEpoch += 1
            mru.promoteToFront(windowID, pid: pid)
            scheduleCacheRefresh()
        }
    }

    /// Watch for app launches and terminations to manage observer lifecycle.
    private func observeAppLifecycle() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                           object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            let pid = app.processIdentifier
            // A just-launched app's AX server may not accept registrations yet;
            // retry once after it has had time to come up.
            if self?.installAXObserver(for: pid) == false {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.installAXObserver(for: pid)
                }
            }
            AppIconCache.shared.prewarm(pid: app.processIdentifier)
            self?.scheduleCacheRefresh()
        }

        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                           object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.removeAXObserver(for: app.processIdentifier)
            self?.mru.forgetApp(app.processIdentifier)
            AppIconCache.shared.evict(pid: app.processIdentifier)
            // Prune the quit app's windows from the cache before the next invoke.
            self?.scheduleCacheRefresh()
        }
    }
}

// Private SPI to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// C callback for AXObserver — bridges to WindowModel.handleFocusedWindowChanged
private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo = userInfo else { return }
    let model = Unmanaged<WindowModel>.fromOpaque(userInfo).takeUnretainedValue()
    model.handleFocusedWindowChanged(element)
}
