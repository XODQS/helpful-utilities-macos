// SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = UtilitiesApp(testMode: CommandLine.arguments.contains("--ui-test"),
                                benchmarkMode: CommandLine.arguments.contains("--benchmark"))
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
