//
//  GatherMerge.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Pure merge policy for lossy window gathers, extracted from WindowModel so
//  it is unit-testable without AppKit or Accessibility. A gather's AX pass can
//  fail for a single wedged/App-Napped app (one 0.25s timeout) while every
//  other app answers; treating that app's missing windows as closed would
//  drop them from the switcher AND destroy their MRU ranks (MRUOrder.sync
//  prunes absent IDs and re-appends them at the tail on the next successful
//  gather). Instead, windows owned by apps that failed to answer are carried
//  over from the previous cache: their IDs stay in the valid set, so sync()
//  preserves their ranks, and the panel keeps showing them. A window that was
//  genuinely closed while its app was unresponsive is carried as a ghost for
//  one round — the ghost-safe confirm path skips it, and the next successful
//  gather prunes it.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import CoreGraphics
import Darwin

enum GatherMerge {

    /// Merges a fresh gather with the previous cache. Windows from `previous`
    /// are carried over when their owning app is in `unresponsivePIDs` (its AX
    /// pass failed, so its windows' absence says nothing) and the gather did
    /// not already find them (its on-screen windows still arrive via the CG
    /// list). Gathered windows come first, carried windows keep their relative
    /// previous order — display order is decided by MRU rank downstream.
    static func merge<T>(
        previous: [T],
        gathered: [T],
        unresponsivePIDs: Set<pid_t>,
        id: (T) -> CGWindowID,
        ownerPID: (T) -> pid_t
    ) -> [T] {
        guard !unresponsivePIDs.isEmpty else { return gathered }
        let gatheredIDs = Set(gathered.map(id))
        let carried = previous.filter {
            unresponsivePIDs.contains(ownerPID($0)) && !gatheredIDs.contains(id($0))
        }
        return gathered + carried
    }
}
