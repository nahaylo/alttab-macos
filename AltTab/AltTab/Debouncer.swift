//
//  Debouncer.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Trailing-edge debouncer: schedule() (re)arms the timer, and the action
//  runs once `interval` after the most recent call. Used to keep the window
//  cache warm — focus changes arrive in bursts (app activation fires both a
//  workspace notification and an AXObserver event; rapid Cmd-` chains fire
//  many), and each gather is a full AX sweep, so refreshes coalesce until the
//  user settles. Queue-confined: call schedule()/cancel() only from `queue`
//  (the main queue in the app); the action also runs there.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  License: MIT
//

import Foundation

final class Debouncer {

    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let action: () -> Void
    private var pending: DispatchWorkItem?

    init(interval: TimeInterval, queue: DispatchQueue = .main, action: @escaping () -> Void) {
        self.interval = interval
        self.queue = queue
        self.action = action
    }

    /// True while a fire is armed and has not yet run or been cancelled.
    var isPending: Bool { pending != nil }

    /// Arms (or re-arms) the timer: the action fires `interval` from now,
    /// superseding any earlier not-yet-fired schedule.
    func schedule() {
        schedule(after: interval)
    }

    /// Arms (or re-arms) the timer with a one-off delay — used to push a fire
    /// past a rate floor without changing the debouncer's base interval.
    func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pending = nil
            self.action()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Disarms a pending fire, if any.
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
