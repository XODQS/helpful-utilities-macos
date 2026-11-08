// SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import UniformTypeIdentifiers

func column(_ views: [NSView], insets: CGFloat = 18) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .fill
    stack.spacing = 11
    stack.edgeInsets = NSEdgeInsets(top: insets, left: insets, bottom: insets, right: insets)
    for view in views {
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * insets).isActive = true
    }
    return stack
}

func row(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = 8
    return stack
}

func hint(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 12)
    field.textColor = .secondaryLabelColor
    field.alignment = .right
    return field
}

func heading(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 22, weight: .semibold)
    field.alignment = .right
    return field
}

func fill(_ view: NSView, in host: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        view.topAnchor.constraint(equalTo: host.topAnchor),
        view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
    ])
}

final class NotesPane: NSView, NSTextViewDelegate {
    private let model: NoteStore
    private let editor = NSTextView()
    private var dots: [NSButton] = []
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                    .systemTeal, .systemBlue, .systemPurple]
    private let previewButton = NSButton(checkboxWithTitle: "معاينة Markdown", target: nil, action: nil)
    private let status = hint("")
    private var selected = 0
    private var pending: Timer?
    private var dirty = false
    private var preview = false

    init(model: NoteStore) {
        self.model = model
        super.init(frame: .zero)
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.font = .systemFont(ofSize: 15)
        editor.drawsBackground = false
        editor.delegate = self
        editor.usesFindBar = true
        dots = colors.enumerated().map { index, color in
            let dot = iconButton("circle.fill", title: "الملاحظة \(index + 1)", target: self, action: #selector(selectNote(_:)))
            dot.tag = index
            dot.contentTintColor = color
            dot.widthAnchor.constraint(equalToConstant: 28).isActive = true
            return dot
        }
        previewButton.target = self
        previewButton.action = #selector(togglePreview)
        let buttons = row([
            NSButton(title: "استيراد ملف…", target: self, action: #selector(importNote)),
            NSButton(title: "تصدير…", target: self, action: #selector(exportNote)),
            NSView(), previewButton
        ])
        let selector = row(dots)
        let header = row([selector, NSView(), heading("ملاحظات")])
        fill(column([header, NSBox.separator(), scroll, NSBox.separator(), status, buttons], insets: 14), in: self)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        loadSelected()
    }

    required init?(coder: NSCoder) { nil }

    @discardableResult func flush() -> Bool {
        pending?.invalidate()
        pending = nil
        guard dirty else { return true }
        do {
            try model.save(editor.string, at: selected)
            dirty = false
            showCount()
            return true
        } catch {
            status.stringValue = "تعذّر الحفظ. النص ما زال مفتوحًا في المحرر."
            return false
        }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        guard let replacementString, let range = Range(affectedCharRange, in: editor.string) else { return true }
        let bytes = editor.string.utf8.count - editor.string[range].utf8.count + replacementString.utf8.count
        if bytes > NoteStore.maxBytes {
            status.stringValue = "الحد الأقصى لكل ملاحظة 512 KiB"
            return false
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        dirty = true
        pending?.invalidate()
        pending = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.flush()
        }
        pending?.tolerance = 0.12
        showCount()
    }

    @objc private func selectNote(_ sender: NSButton) {
        guard flush() else { return }
        selected = sender.tag
        loadSelected()
        if !preview { window?.makeFirstResponder(editor) }
    }

    func focus() { if !preview { window?.makeFirstResponder(editor) } }

    @objc private func togglePreview() {
        guard flush() else {
            previewButton.state = preview ? .on : .off
            return
        }
        preview = previewButton.state == .on
        loadSelected()
    }

    private func loadSelected() {
        for (index, button) in dots.enumerated() {
            let label = "الملاحظة \(index + 1)" + (index == selected ? "، محددة" : "")
            button.image = symbol(index == selected ? "circle.inset.filled" : "circle.fill", size: index == selected ? 17 : 11)
            button.setAccessibilityLabel(label)
        }
        let text = model.notes[selected]
        editor.insertionPointColor = colors[selected]
        editor.isEditable = !preview
        if preview {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let formatted = (try? AttributedString(markdown: text, options: options)).map(NSAttributedString.init)
            let visible = NSMutableAttributedString(attributedString: formatted ?? NSAttributedString(string: text))
            let range = NSRange(location: 0, length: visible.length)
            visible.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            visible.enumerateAttribute(.font, in: range) { value, run, _ in
                let font = value as? NSFont ?? .systemFont(ofSize: 15)
                visible.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: 15), range: run)
            }
            editor.textStorage?.setAttributedString(visible)
        } else {
            editor.string = text
            editor.font = .systemFont(ofSize: 15)
        }
        editor.undoManager?.removeAllActions()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        showCount()
    }

    private func showCount() {
        let text = preview ? model.notes[selected] : editor.string
        let words = text.split(whereSeparator: \.isWhitespace).count
        let saving = dirty ? "  ·  جارٍ الحفظ" : ""
        status.stringValue = "\(words) كلمة  ·  \(text.count) حرف  ·  محفوظ محليًا\(saving)"
    }

    @objc private func importNote() {
        guard flush() else { return }
        let slot = selected
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= NoteStore.maxBytes else { throw CocoaError(.fileReadTooLarge) }
                let text = try String(contentsOf: url, encoding: .utf8)
                if !self.model.notes[slot].isEmpty {
                    let confirm = NSAlert()
                    confirm.messageText = "استبدال محتوى الملاحظة \(slot + 1)؟"
                    confirm.addButton(withTitle: "استبدال")
                    confirm.addButton(withTitle: "إلغاء")
                    guard confirm.runModal() == .alertFirstButtonReturn else { return }
                }
                try self.model.save(text, at: slot)
                self.loadSelected()
            } catch { self.status.stringValue = "تعذّر الاستيراد. اختر ملف UTF-8 بحجم 512 KiB أو أقل." }
        }
    }

    @objc private func exportNote() {
        guard flush() else { return }
        let text = model.notes[selected]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ملاحظة-\(selected + 1).md"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.status.stringValue = "تعذّر تصدير الملاحظة." }
        }
    }
}
