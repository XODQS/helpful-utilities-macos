// SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import ApplicationServices
import ScreenCaptureKit

struct Shortcut {
    let title: String
    let group: String
    let keys: String
    var enabled = true
    var element: AXUIElement?
    var screenshot: ScreenshotShortcut?
}

struct AppTarget {
    let pid: pid_t
    let name: String

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        name = app.localizedName ?? "تطبيق"
    }
}

struct SwitchWindow {
    let target: AppTarget
    let element: AXUIElement?
    let title: String
    let minimized: Bool
}

enum DesktopAccess {
    static var allowed: Bool { AXIsProcessTrusted() }

    static func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func read<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else {
            return nil
        }
        return result as? T
    }

    private static let configureTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.15)
    }()

    static func application(_ pid: pid_t) -> AXUIElement {
        _ = configureTimeout
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        return app
    }

    static func shortcuts(for target: AppTarget) -> [Shortcut] {
        let app = application(target.pid)
        guard let bar: AXUIElement = read(app, kAXMenuBarAttribute) else { return [] }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.4
        var budget = 1100
        var matches: [Shortcut] = []

        func walk(_ node: AXUIElement, path: [String], depth: Int) {
            guard depth < 12, budget > 0,
                  ProcessInfo.processInfo.systemUptime < deadline else { return }
            budget -= 1
            let role: String? = read(node, kAXRoleAttribute)
            let title: String = read(node, kAXTitleAttribute) ?? ""
            if role == kAXMenuItemRole, !title.isEmpty {
                let char: String = read(node, kAXMenuItemCmdCharAttribute) ?? ""
                let glyph: Int = char.isEmpty ? read(node, kAXMenuItemCmdGlyphAttribute) ?? 0 : 0
                if let key = shortcutKey(character: char, glyph: glyph) {
                    let modifiers: Int = read(node, kAXMenuItemCmdModifiersAttribute) ?? 0
                    let enabled: Bool = read(node, kAXEnabledAttribute) ?? true
                    matches.append(Shortcut(title: title, group: path.joined(separator: " › "),
                                            keys: shortcutLabel(modifiers: modifiers, key: key),
                                            enabled: enabled, element: node))
                }
            }
            let nextPath = !title.isEmpty && role != kAXMenuRole ? path + [title] : path
            for child in children(of: node, limit: min(160, budget)) {
                guard budget > 0, ProcessInfo.processInfo.systemUptime < deadline else { break }
                walk(child, path: nextPath, depth: depth + 1)
            }
        }

        for menu in children(of: bar, limit: 40) {
            walk(menu, path: [], depth: 0)
        }
        return matches
    }

    static func press(_ shortcut: Shortcut, in target: AppTarget) -> Bool {
        guard shortcut.enabled, let element = shortcut.element else { return false }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == target.pid,
              let role: String = read(element, kAXRoleAttribute), role == kAXMenuItemRole,
              let title: String = read(element, kAXTitleAttribute), title == shortcut.title,
              (read(element, kAXEnabledAttribute) as Bool?) != false else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static func children(of element: AXUIElement, limit: Int) -> [AXUIElement] {
        var total = 0
        var result: CFArray?
        let attribute = kAXChildrenAttribute as CFString
        guard limit > 0,
              AXUIElementGetAttributeValueCount(element, attribute, &total) == .success, total > 0,
              AXUIElementCopyAttributeValues(element, attribute, 0, min(total, limit), &result) == .success
        else { return [] }
        return result as? [AXUIElement] ?? []
    }

    static func shortcutLabel(modifiers: Int, key: String) -> String {
        var prefix = ""
        if modifiers & 4 != 0 { prefix += "⌃" }
        if modifiers & 2 != 0 { prefix += "⌥" }
        if modifiers & 1 != 0 { prefix += "⇧" }
        if modifiers & 8 == 0 { prefix += "⌘" }
        return prefix + key
    }

    private static func shortcutKey(character: String, glyph: Int) -> String? {
        if let replacement = ["\r": "↩", "\n": "↩", "\t": "⇥", "\u{1B}": "⎋",
                              "\u{08}": "⌫", "\u{7F}": "⌫", " ": "Space"][character] {
            return replacement
        }
        if !character.isEmpty { return character.uppercased() }
        guard glyph != 0 else { return nil }
        // Glyph codes are the Carbon Menu Manager's kMenu…Glyph values.
        let names = [2: "⇥", 3: "⇤", 4: "⌤", 9: "Space", 10: "⌦", 11: "↩", 12: "↩",
                     13: "↩", 23: "⌫", 27: "⎋", 0x62: "⇞", 0x64: "←", 0x65: "→",
                     0x68: "↑", 0x6a: "↓", 0x6b: "⇟"]
        if let name = names[glyph] { return name }
        if (0x6f...0x7a).contains(glyph) { return "F\(glyph - 0x6e)" }
        if (0x87...0x89).contains(glyph) { return "F\(glyph - 0x7a)" }
        if (0x8f...0x92).contains(glyph) { return "F\(glyph - 0x7f)" }
        return nil
    }

    static func windows(for targets: [AppTarget]) -> [SwitchWindow] {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.9
        var result: [SwitchWindow] = []
        for target in targets.prefix(40) {
            guard ProcessInfo.processInfo.systemUptime < deadline, result.count < 100 else { break }
            let app = application(target.pid)
            let windows: [AXUIElement] = read(app, kAXWindowsAttribute) ?? []
            let focused: AXUIElement? = read(app, kAXFocusedWindowAttribute)
            let ordered = focused.map { focus in
                windows.filter { CFEqual($0, focus) } + windows.filter { !CFEqual($0, focus) }
            } ?? windows
            for window in ordered.prefix(30) {
                guard ProcessInfo.processInfo.systemUptime < deadline, result.count < 100 else { break }
                let role: String? = read(window, kAXSubroleAttribute)
                guard role == nil || role == kAXStandardWindowSubrole || role == kAXDialogSubrole else { continue }
                let title: String = read(window, kAXTitleAttribute) ?? ""
                let minimized: Bool = read(window, kAXMinimizedAttribute) ?? false
                result.append(SwitchWindow(target: target, element: window,
                                           title: title.isEmpty ? target.name : title, minimized: minimized))
            }
        }
        let onscreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var visibleRanks: [String: Int] = [:]
        for (index, item) in onscreen.enumerated() {
            guard item[kCGWindowLayer as String] as? Int == 0,
                  let pid = item[kCGWindowOwnerPID as String] as? Int,
                  let title = item[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            let key = "\(pid)/\(title)"
            if visibleRanks[key] == nil { visibleRanks[key] = index }
        }
        return result.enumerated().sorted { left, right in
            func rank(_ value: (offset: Int, element: SwitchWindow)) -> Int {
                let window = value.element
                return visibleRanks["\(window.target.pid)/\(window.title)"] ?? (onscreen.count + value.offset)
            }
            let a = rank(left), b = rank(right)
            return a == b ? left.offset < right.offset : a < b
        }.map(\.element)
    }

    static func focus(_ window: SwitchWindow) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.target.pid),
              !app.isTerminated, let element = window.element else { return false }
        if app.isHidden { app.unhide() }
        if window.minimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let focused = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let activated = app.activate(options: [.activateIgnoringOtherApps])
        return activated && (focused == .success || raised == .success)
    }

}

@available(macOS 14.0, *)
struct WindowPreviewSource {
    let windows: [SCWindow]

    static func load() async -> WindowPreviewSource? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return nil }
        return WindowPreviewSource(windows: content.windows)
    }

    func image(for window: SwitchWindow) async -> CGImage? {
        guard !window.minimized, !Task.isCancelled else { return nil }
        let matches = windows.filter {
            $0.owningApplication?.processID == window.target.pid && $0.title == window.title && $0.windowLayer == 0
        }
        guard matches.count == 1, let match = matches.first,
              match.frame.width > 0, match.frame.height > 0 else { return nil }
        let scale = min(1, 352 / match.frame.width, 204 / match.frame.height)
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(match.frame.width * scale))
        configuration.height = max(2, Int(match.frame.height * scale))
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: match)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
