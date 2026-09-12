// swift-tools-version:5.9
//
// SPM manifest used ONLY to unit-test the pure-logic core with `swift test`.
// The `sources:` allow-list below is the authoritative set of files compiled
// into AltTabCore; the app builds through AltTab/AltTab.xcodeproj and compiles
// the same files, so they must stay free of AppKit imports.
//
import PackageDescription

let package = Package(
    name: "AltTabCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "AltTabCore",
            path: "AltTab/AltTab",
            exclude: [
                "AppDelegate.swift",
                "HotkeyManager.swift",
                "WindowModel.swift",
                "WindowCapture.swift",
                "WindowActivator.swift",
                "SwitcherPanel.swift",
                "ThumbnailView.swift",
                "PermissionManager.swift",
                "PreferencesMenu.swift",
                "main.swift",
                "Assets.xcassets",
                "Info.plist",
                "AltTab.entitlements",
            ],
            sources: ["MRUOrder.swift", "SwitcherStateMachine.swift", "SwitcherSelection.swift",
                      "WCAGContrast.swift", "GatherMerge.swift", "Debouncer.swift"]
        ),
        .testTarget(
            name: "AltTabCoreTests",
            dependencies: ["AltTabCore"],
            path: "Tests/AltTabCoreTests"
        ),
    ]
)
