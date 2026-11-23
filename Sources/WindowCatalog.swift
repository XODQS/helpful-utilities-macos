// SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

/// Accessed on the main thread. Each app's accessibility queries run independently.
final class WindowCatalog {
    private struct Entry {
        let windows: [SwitchWindow]
        let updated: TimeInterval
    }

    private let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "helpful.window-discovery"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var entries: [pid_t: Entry] = [:]
    private var pending = Set<pid_t>()

    private let readWindows: (AppTarget) -> [SwitchWindow]?
    var onRefresh: (() -> Void)?

    init(readWindows: @escaping (AppTarget) -> [SwitchWindow]? = DesktopAccess.windows(for:)) {
        self.readWindows = readWindows
    }

    func refresh(_ targets: [AppTarget]) {
        let live = Set(targets.map(\.pid))
        entries = entries.filter { live.contains($0.key) }
        let now = ProcessInfo.processInfo.systemUptime
        for target in targets {
            if let entry = entries[target.pid], now - entry.updated < 1 { continue }
            guard pending.insert(target.pid).inserted else { continue }
            workers.addOperation { [weak self, readWindows] in
                let windows = readWindows(target)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pending.remove(target.pid)
                    if let windows {
                        self.entries[target.pid] = Entry(windows: windows, updated: ProcessInfo.processInfo.systemUptime)
                    }
                    if self.pending.isEmpty { self.onRefresh?() }
                }
            }
        }
    }

    func snapshot(_ targets: [AppTarget]) -> [SwitchWindow] {
        var first: [SwitchWindow] = []
        var others: [SwitchWindow] = []
        let now = ProcessInfo.processInfo.systemUptime
        for target in targets {
            if let entry = entries[target.pid], now - entry.updated < 120, let window = entry.windows.first {
                first.append(window)
                others.append(contentsOf: entry.windows.dropFirst())
            } else {
                first.append(SwitchWindow(target: target, element: nil, title: target.name, minimized: false))
            }
        }
        return first + others
    }
}
