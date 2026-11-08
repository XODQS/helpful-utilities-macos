// SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Carbon

enum ScreenshotShortcut: Int, CaseIterable {
    case saveScreen = 28
    case copyScreen = 29
    case saveSelection = 30
    case copySelection = 31
    case toolbar = 184

    private var title: String {
        switch self {
        case .saveScreen: "حفظ لقطة للشاشة"
        case .copyScreen: "نسخ لقطة الشاشة إلى الحافظة"
        case .saveSelection: "حفظ لقطة لجزء من الشاشة"
        case .copySelection: "نسخ جزء من الشاشة إلى الحافظة"
        case .toolbar: "فتح أدوات لقطة الشاشة"
        }
    }

    private var defaultKeys: String {
        switch self {
        case .saveScreen: "⇧⌘3"
        case .copyScreen: "⌃⇧⌘3"
        case .saveSelection: "⇧⌘4"
        case .copySelection: "⌃⇧⌘4"
        case .toolbar: "⇧⌘5"
        }
    }

    static func entries() -> [Shortcut] {
        let overrides = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        return allCases.compactMap { action in
            let entry = overrides?[String(action.rawValue)] as? [String: Any]
            if entry?["enabled"] as? Bool == false { return nil }
            let value = entry?["value"] as? [String: Any]
            let parameters = value?["parameters"] as? [Int]
            let keys = parameters.flatMap(action.configuredKeys) ?? action.defaultKeys
            return Shortcut(title: action.title, group: "لقطات الشاشة في macOS", keys: keys, screenshot: action)
        }
    }

    private func configuredKeys(_ parameters: [Int]) -> String? {
        guard parameters.count == 3 else { return nil }
        let key = parameters[1]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
                            kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14,
                            kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let named = [kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Tab: "⇥",
                     kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        let name: String
        if let index = functionKeys.firstIndex(of: key) {
            name = "F\(index + 1)"
        } else if let label = named[key] {
            name = label
        } else if let character = UnicodeScalar(parameters[0]), !CharacterSet.controlCharacters.contains(character),
                  character.value != 0xffff {
            name = String(character).uppercased()
        } else {
            return "مخصص"
        }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(max(0, parameters[2])))
        let mask = (flags.contains(.shift) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
                 | (flags.contains(.control) ? 4 : 0) | (flags.contains(.command) ? 0 : 8)
        return DesktopAccess.shortcutLabel(modifiers: mask, key: name)
    }

    func run(onError: @escaping (String) -> Void) {
        if self == .toolbar {
            let url = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                if let error { DispatchQueue.main.async { onError(error.localizedDescription) } }
            }
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            onError("فعّل إذن معاينة الشاشة من إعدادات macOS ثم جرّب مرة أخرى.")
            return
        }
        var arguments = ["-x"]
        if self == .saveSelection || self == .copySelection { arguments.append("-i") }
        if self == .copyScreen || self == .copySelection {
            arguments.append("-c")
        } else {
            let configured = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            let folder = configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
                .flatMap { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true ? $0 : nil } ?? desktop
            guard let folder else { onError("تعذّر العثور على مجلد حفظ اللقطات."); return }
            let filename = "لقطة شاشة \(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png"
            arguments.append(folder.appendingPathComponent(filename).path)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = arguments
        task.terminationHandler = { task in
            if task.terminationStatus != 0 && self != .saveSelection && self != .copySelection {
                DispatchQueue.main.async { onError("تعذّر التقاط الشاشة. تحقّق من الإذن ومجلد حفظ اللقطات.") }
            }
        }
        do { try task.run() } catch { onError(error.localizedDescription) }
    }
}
