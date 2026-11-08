// SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

func symbol(_ name: String, size: CGFloat = 14) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
}

func iconButton(_ icon: String, title: String, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(image: symbol(icon) ?? NSImage(), target: target, action: action)
    button.isBordered = false
    button.toolTip = title
    button.setAccessibilityLabel(title)
    return button
}

extension NSBox {
    static func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }
}

final class ClipPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    let search = NSSearchField()
    private let table = NSTableView()
    private let footer = hint("")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let recordButton = NSButton(title: "تشغيل التسجيل", target: nil, action: nil)
    private var clips: [Clip] = []
    private var matches: [Int] = []
    private var recording = false
    private var storageIssue = false
    var choose: ((Clip) -> Void)?
    var remove: ((Clip) -> Void)?
    var startRecording: (() -> Void)?
    var dismiss: (() -> Void)?

    init() {
        super.init(frame: .zero)
        search.placeholderString = "ابحث في النصوص المنسوخة"
        search.setAccessibilityLabel("بحث في الحافظة")
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.target = self
        search.action = #selector(filter)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        table.backgroundColor = .clear
        table.headerView = nil
        table.rowHeight = 42
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.intercellSpacing = .init(width: 0, height: 3)
        table.style = .inset
        table.addTableColumn(NSTableColumn(identifier: .init("clip")))
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(clicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let content = NSView()
        fill(scroll, in: content)
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        let glyph = NSImageView(image: symbol("clipboard", size: 28) ?? NSImage())
        glyph.contentTintColor = .tertiaryLabelColor
        recordButton.target = self
        recordButton.action = #selector(start)
        let emptyGroup = column([glyph, empty, row([NSView(), recordButton, NSView()])], insets: 0)
        emptyGroup.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyGroup)
        NSLayoutConstraint.activate([
            emptyGroup.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyGroup.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -10),
            emptyGroup.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.82)
        ])
        emptyView = emptyGroup
        footer.alignment = .right
        fill(column([search, content, NSBox.separator(), footer], insets: 14), in: self)
        filter()
    }

    private weak var emptyView: NSView?
    required init?(coder: NSCoder) { nil }

    func prepare() {
        search.stringValue = ""
        filter()
        window?.makeFirstResponder(search)
    }

    func update(_ clips: [Clip], recording: Bool, storageIssue: Bool) {
        self.clips = clips
        self.recording = recording
        self.storageIssue = storageIssue
        filter()
    }

    @objc private func filter() {
        let term = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        matches = clips.indices.filter { term.isEmpty || clips[$0].text.localizedStandardContains(term) }
        table.reloadData()
        if !matches.isEmpty { select(0) }
        emptyView?.isHidden = !matches.isEmpty
        recordButton.isHidden = recording || !term.isEmpty
        empty.stringValue = !term.isEmpty ? "ما لقينا نصًا يطابق بحثك."
            : recording ? "انسخ أي نص وسيظهر هنا." : "شغّل التسجيل للاحتفاظ بالنصوص التي تنسخها."
        footer.stringValue = storageIssue ? "تعذّر حفظ آخر تغيير"
            : "نسخ المحدد \u{2066}↵\u{2069}   ·   التنقّل \u{2066}↑ ↓\u{2069}   ·   فتح الحافظة \u{2066}⌃⌥V\u{2069}"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let clip = clips[matches[index]]
        let label = NSTextField(labelWithString: clip.label)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        let time = hint(clip.date.formatted(date: .omitted, time: .shortened))
        time.alignment = .natural
        let icon = NSImageView(image: symbol("text.alignleft") ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = row([icon, label, NSView(), time])
        stack.alignment = .centerY
        stack.edgeInsets = .init(top: 5, left: 10, bottom: 5, right: 10)
        let view = NSView()
        fill(stack, in: view)
        return view
    }

    private func select(_ index: Int) {
        guard !matches.isEmpty else { return }
        let selected = min(max(index, 0), matches.count - 1)
        table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        table.scrollRowToVisible(selected)
    }

    func controlTextDidChange(_ notification: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)): copyRow(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): dismiss?()
        default: return false
        }
        return true
    }

    private func copyRow(_ index: Int) {
        if matches.indices.contains(index) { choose?(clips[matches[index]]) }
    }

    @objc private func clicked() { copyRow(table.clickedRow) }
    @objc private func start() { startRecording?() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard matches.indices.contains(table.clickedRow) else { return }
        let clip = clips[matches[table.clickedRow]]
        let item = NSMenuItem(title: "حذف هذا النص", action: #selector(deleteClip(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = clip.text
        menu.addItem(item)
    }

    @objc private func deleteClip(_ item: NSMenuItem) {
        guard let text = item.representedObject as? String,
              let clip = clips.first(where: { $0.text == text }) else { return }
        remove?(clip)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

func shortcutGroups(_ commands: [Shortcut]) -> [(title: String, commands: [Shortcut])] {
    var groups: [String] = []
    var byName: [String: [Shortcut]] = [:]
    for command in commands {
        let name = command.group.isEmpty ? "عام" : command.group
        if byName[name] == nil { groups.append(name) }
        byName[name, default: []].append(command)
    }
    return groups.map { ($0, byName[$0] ?? []) }
}

private final class ShortcutButton: NSButton {
    private let activate: () -> Void

    init(_ shortcut: Shortcut, activate: @escaping () -> Void) {
        self.activate = activate
        super.init(frame: .zero)
        title = ""
        isBordered = false
        isEnabled = shortcut.enabled
        target = self
        action = #selector(run)
        setAccessibilityLabel("\(shortcut.title)، \(shortcut.keys)")
        toolTip = shortcut.enabled ? "تنفيذ \(shortcut.title)" : "الأمر غير متاح في التطبيق الآن"
        let name = NSTextField(labelWithString: shortcut.title)
        name.font = .systemFont(ofSize: 12)
        name.maximumNumberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keys = NSTextField(labelWithString: shortcut.keys)
        keys.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        keys.textColor = shortcut.enabled ? .controlAccentColor : .tertiaryLabelColor
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        if !shortcut.enabled { name.textColor = .tertiaryLabelColor }
        let labels = row([name, NSView(), keys])
        labels.alignment = .centerY
        labels.setAccessibilityElement(false)
        fill(labels, in: self)
        heightAnchor.constraint(equalToConstant: 21).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    @objc private func run() { if isEnabled { activate() } }
}

final class ShortcutBoard: NSView, NSSearchFieldDelegate {
    let search = NSSearchField()
    private let title = heading("اختصارات التطبيق")
    private let caption = hint("")
    private var printButton: NSButton?
    var onChoose: ((Shortcut) -> Void)?
    var onPrint: ((String, [Shortcut]) -> Void)?
    var onDismiss: (() -> Void)?
    private let scroll = NSScrollView()
    private let host = FlippedView()
    private var content: NSView?
    private var matches: [Shortcut] = []
    private let columns: Int

    init(transient: Bool) {
        columns = transient ? 3 : 2
        super.init(frame: .zero)
        search.placeholderString = "ابحث عن أمر أو اختصار"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = host
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            host.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        let printButton = iconButton("printer", title: "طباعة الاختصارات أو حفظها PDF", target: self,
                                     action: #selector(printList))
        printButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        printButton.isEnabled = false
        self.printButton = printButton
        let header = row([printButton, NSView(), title])
        header.alignment = .centerY
        fill(column(transient ? [header, caption, scroll] : [header, caption, search, scroll], insets: 15), in: self)
    }

    required init?(coder: NSCoder) { nil }

    func update(app: String, shortcuts: [Shortcut], caption: String) {
        title.stringValue = app
        self.caption.stringValue = caption
        matches = shortcuts
        printButton?.isEnabled = !shortcuts.isEmpty
        rebuild()
    }

    func showStatus(_ value: String) { caption.stringValue = value }

    func controlTextDidChange(_ notification: Notification) { rebuild() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), search.stringValue.isEmpty else { return false }
        onDismiss?()
        return true
    }

    @objc private func printList() { if !matches.isEmpty { onPrint?(title.stringValue, matches) } }

    private func rebuild() {
        content?.removeFromSuperview()
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = matches.filter {
            query.isEmpty || $0.title.localizedStandardContains(query)
                          || $0.group.localizedStandardContains(query) || $0.keys.localizedStandardContains(query)
        }
        let stacks = (0..<columns).map { _ in column([], insets: 0) }
        var loads = Array(repeating: 0, count: columns)
        for (group, values) in shortcutGroups(visible) {
            guard let index = loads.indices.min(by: { loads[$0] < loads[$1] }) else { continue }
            let heading = hint(group)
            heading.font = .systemFont(ofSize: 11, weight: .semibold)
            heading.maximumNumberOfLines = 1
            heading.lineBreakMode = .byTruncatingTail
            let rows = values.map { shortcut in
                ShortcutButton(shortcut) { [weak self] in self?.onChoose?(shortcut) }
            }
            let card = column([heading, NSBox.separator()] + rows, insets: 9)
            card.spacing = 5
            card.wantsLayer = true
            card.layer?.cornerRadius = 9
            card.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.065).cgColor
            stacks[index].addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stacks[index].widthAnchor).isActive = true
            loads[index] += values.count + 2
        }
        let grid = row(stacks)
        grid.alignment = .top
        grid.distribution = .fillEqually
        content = grid
        fill(grid, in: host)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
