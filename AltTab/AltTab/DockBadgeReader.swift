//
//  DockBadgeReader.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Reads app badges (unread counts, "•" dots) off the Dock's Accessibility
//  tree: each running app's Dock item exposes the badge as its AXStatusLabel.
//  Apps do not publish their badge to other processes any other way, and the
//  Accessibility permission the event tap already needs covers this read.
//  The walk is synchronous AX IPC, so it runs on a private queue and delivers
//  on the main thread; DockBadges (pure, unit-tested) matches items to pids.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import Cocoa
import ApplicationServices

final class DockBadgeReader {

    private static let queue = DispatchQueue(label: "com.alttab.dock-badges", qos: .userInitiated)
    /// The Dock answers fast; a wedged Dock must not hold the switcher's
    /// badges (and this queue) for the ~6s AX default.
    private static let axTimeout: Float = 0.5
    private static let dockBundleID = "com.apple.dock"
    private static let applicationDockItemSubrole = "AXApplicationDockItem"
    private static let statusLabelAttribute = "AXStatusLabel"

    /// Reads the Dock's application items off the main thread; `completion`
    /// runs on the main thread with an empty list if the Dock is unreachable.
    func read(completion: @escaping ([DockBadges.Item]) -> Void) {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else {
            completion([])
            return
        }
        let dockPID = dock.processIdentifier
        Self.queue.async {
            let items = Self.readItems(dockPID: dockPID)
            DispatchQueue.main.async { completion(items) }
        }
    }

    // MARK: - AX walk (background queue)

    private static func readItems(dockPID: pid_t) -> [DockBadges.Item] {
        let axDock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(axDock, axTimeout)
        guard let lists = copy(axDock, kAXChildrenAttribute) as? [AXUIElement] else { return [] }

        var items: [DockBadges.Item] = []
        for list in lists {
            // Timeouts are per element (see CLAUDE.md): set on every element touched.
            AXUIElementSetMessagingTimeout(list, axTimeout)
            guard (copy(list, kAXRoleAttribute) as? String) == kAXListRole,
                  let dockItems = copy(list, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for item in dockItems {
                AXUIElementSetMessagingTimeout(item, axTimeout)
                guard (copy(item, kAXSubroleAttribute) as? String) == applicationDockItemSubrole else { continue }
                let title = copy(item, kAXTitleAttribute) as? String ?? ""
                let url = copy(item, kAXURLAttribute) as? NSURL
                let badge = copy(item, statusLabelAttribute) as? String
                items.append(DockBadges.Item(bundlePath: url?.path, title: title, badge: badge))
            }
        }
        return items
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
