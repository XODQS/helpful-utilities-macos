// SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

enum ShortcutPrinting {
    static func run(app: String, commands: [Shortcut]) {
        guard !commands.isEmpty, let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let printableWidth = max(120, info.paperSize.width - info.leftMargin - info.rightMargin)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: printableWidth, height: 1))
        view.drawsBackground = false
        view.isEditable = false
        view.textContainerInset = .init(width: 4, height: 3)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: printableWidth - 8, height: CGFloat.greatestFiniteMagnitude)

        let text = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        paragraph.alignment = .natural
        func line(_ value: String, size: CGFloat, weight: NSFont.Weight, dimmed: Bool = false) {
            text.append(NSAttributedString(string: value + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: dimmed ? NSColor.darkGray : NSColor.black,
                .paragraphStyle: paragraph
            ]))
        }
        line(app, size: 24, weight: .bold)
        line("اختصارات قوائم التطبيق", size: 12, weight: .medium, dimmed: true)
        for (group, shortcuts) in shortcutGroups(commands) {
            line("", size: 6, weight: .regular)
            line(group, size: 13, weight: .semibold)
            for shortcut in shortcuts {
                line("\(shortcut.title)     \u{2066}\(shortcut.keys)\u{2069}", size: 11,
                     weight: .regular, dimmed: !shortcut.enabled)
            }
        }
        view.textStorage?.setAttributedString(text)
        if let manager = view.layoutManager, let container = view.textContainer {
            manager.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: printableWidth, height: ceil(manager.usedRect(for: container).height) + 8))
        }
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = "اختصارات \(app)"
        operation.printPanel.options.insert(.showsPreview)
        operation.run()
    }
}
