// SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

private final class WindowCard: NSView {
    private let preview = NSImageView()
    private let icon = NSImageView()
    private let name = hint("")
    private let title = NSTextField(labelWithString: "")
    private let backdrop = NSView()
    var activate: (() -> Void)?

    init(window: SwitchWindow, image: NSImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 8
        backdrop.layer?.masksToBounds = true
        backdrop.heightAnchor.constraint(equalToConstant: 99).isActive = true
        backdrop.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        preview.imageScaling = .scaleProportionallyUpOrDown
        fill(preview, in: backdrop)

        icon.image = image ?? symbol("macwindow", size: 26)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let fallback = NSImageView(image: image ?? symbol("macwindow", size: 35) ?? NSImage())
        fallback.imageScaling = .scaleProportionallyUpOrDown
        fallback.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(fallback)
        NSLayoutConstraint.activate([
            fallback.widthAnchor.constraint(equalToConstant: 42), fallback.heightAnchor.constraint(equalToConstant: 42),
            fallback.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            fallback.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor)
        ])
        fallbackIcon = fallback
        title.stringValue = window.title
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        name.stringValue = (window.element == nil ? "تطبيق" : window.target.name) + (window.minimized ? "  ·  مصغّرة" : "")
        name.alignment = .natural
        name.font = .systemFont(ofSize: 10)
        for field in [title, name] {
            field.maximumNumberOfLines = 1
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = column([title, name], insets: 0)
        labels.spacing = 2
        let footer = row([icon, labels])
        footer.alignment = .centerY
        labels.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -32).isActive = true
        let stack = column([backdrop, footer], insets: 8)
        stack.spacing = 8
        fill(stack, in: self)
        widthAnchor.constraint(equalToConstant: 166).isActive = true
        heightAnchor.constraint(equalToConstant: 155).isActive = true
        let click = NSClickGestureRecognizer(target: self, action: #selector(pick))
        addGestureRecognizer(click)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(window.target.name)، \(window.title)")
        highlight(false)
    }

    private weak var fallbackIcon: NSImageView?
    required init?(coder: NSCoder) { nil }

    func highlight(_ selected: Bool) {
        let color = NSColor.controlAccentColor
        layer?.borderWidth = selected ? 2 : 1
        layer?.borderColor = (selected ? color : NSColor.separatorColor).cgColor
        layer?.backgroundColor = (selected ? color.withAlphaComponent(0.16) : NSColor.labelColor.withAlphaComponent(0.035)).cgColor
        setAccessibilitySelected(selected)
    }

    func setPreview(_ image: CGImage) {
        preview.image = NSImage(cgImage: image, size: .zero)
        fallbackIcon?.isHidden = true
    }

    override func accessibilityPerformPress() -> Bool { pick(); return true }
    @objc private func pick() { activate?() }
}

final class WindowSwitcher: NSObject, NSWindowDelegate {
    private let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 230),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
    private let scroll = NSScrollView()
    private let strip = NSStackView()
    private let title = heading("تبديل النوافذ")
    private let caption = hint("")
    private var windows: [SwitchWindow] = []
    private var cards: [Int: WindowCard] = [:]
    private var isRendering = false
    private var manual = false
    private var userNavigated = false
    private var selected = 0
    private var request = UUID()
    private var previewTask: Task<Void, Never>?
    private var attempted = Set<Int>()
    private var previewSource: Any?
    private var pendingFocus: BlockOperation?
    private let queue = DispatchQueue(label: "helpful.window-access", qos: .userInitiated)
    var previewsEnabled = false
    private(set) var active = false

    override init() {
        super.init()
        panel.title = "تبديل النوافذ"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onKey = { [weak self] event in
            switch event.keyCode {
            case 123: self?.move(-1)
            case 124, 48: self?.move(1)
            case 36: self?.commit()
            case 53: self?.cancel()
            default: return false
            }
            return true
        }
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 21
        material.layer?.masksToBounds = true

        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.heightAnchor.constraint(equalToConstant: 168).isActive = true
        strip.orientation = .horizontal
        strip.alignment = .centerY
        strip.spacing = 9
        strip.edgeInsets = .init(top: 1, left: 1, bottom: 7, right: 1)
        scroll.documentView = strip
        strip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            strip.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            strip.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        ])
        let close = iconButton("xmark.circle.fill", title: "إغلاق", target: self, action: #selector(cancel))
        close.contentTintColor = .secondaryLabelColor
        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        fill(surface, in: material)
        fill(column([row([close, NSView(), title]), scroll, caption], insets: 14), in: surface)
        panel.contentView = material
    }

    func show(_ available: [SwitchWindow], step: Int?, front: pid_t?) {
        if active, let step { move(step); return }
        pendingFocus?.cancel()
        cancel()
        active = true
        windows = available
        manual = step == nil
        // The first pass contains one entry per app in activation order.
        let base = step == 1 && available.first?.target.pid != front ? -1 : 0
        select(base + (step ?? 0))
        let current = request
        let present = { [weak self] in
            guard let self, self.active, self.request == current else { return }
            self.isRendering = true
            self.position(width: max(350, min(905, CGFloat(self.windows.count) * 175 + 26)))
            self.render()
            if self.manual { self.panel.makeKeyAndOrderFront(nil); self.panel.makeFirstResponder(self.panel) }
            else { self.panel.orderFrontRegardless() }
        }
        if manual { present() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: present) }
    }

    func displaySample(_ sample: [SwitchWindow]) {
        show(sample, step: nil, front: nil)
        move(1)
    }

    private func position(width: CGFloat) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let width = min(width, frame.width - 36)
        let size = NSSize(width: width, height: 246)
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }

    func update(_ refreshed: [SwitchWindow]) {
        guard active, !userNavigated, windows.indices.contains(selected) else { return }
        let prior = windows[selected]
        let exact = refreshed.firstIndex { candidate in
            guard let a = prior.element, let b = candidate.element else { return false }
            return CFEqual(a, b)
        }
        guard let index = exact ?? refreshed.firstIndex(where: { $0.target.pid == prior.target.pid }) else { return }
        if isRendering {
            request = UUID()
            clearCards()
        }
        windows = refreshed
        if isRendering { position(width: max(350, min(905, CGFloat(windows.count) * 175 + 26))) }
        select(index)
    }

    func move(_ amount: Int) {
        userNavigated = true
        select(selected + amount)
    }

    private func select(_ index: Int) {
        guard !windows.isEmpty else { return }
        selected = (index % windows.count + windows.count) % windows.count
        if isRendering { render() }
    }

    private func render() {
        guard !windows.isEmpty else {
            caption.stringValue = "افتح تطبيقًا بنافذة ثم حاول مرة أخرى."
            return
        }
        // Only build cards near the selection, even with hundreds of open windows.
        let start = min(max(0, selected - 2), max(0, windows.count - 5))
        let range = start..<min(start + 5, windows.count)
        for index in Array(cards.keys) where !range.contains(index) {
            if let card = cards.removeValue(forKey: index) {
                strip.removeArrangedSubview(card)
                card.removeFromSuperview()
                attempted.remove(index)
            }
        }
        for index in range {
            let window = windows[index]
            if cards[index] == nil {
                let card = WindowCard(window: window, image: NSRunningApplication(processIdentifier: window.target.pid)?.icon)
                card.activate = { [weak self] in self?.select(index); self?.commit() }
                cards[index] = card
                strip.insertArrangedSubview(card, at: index - start)
            }
            cards[index]?.highlight(index == selected)
        }
        strip.layoutSubtreeIfNeeded()
        if let card = cards[selected] { strip.scrollToVisible(card.frame.insetBy(dx: -6, dy: 0)) }
        let action = manual ? "اضغط ↵ أو انقر للاختيار" : "أفلت ⌘ للاختيار"
        caption.stringValue = "\(selected + 1) من \(windows.count)   ·   \(action)   ·   Esc للإلغاء"
        loadPreviews(around: selected)
    }

    private func loadPreviews(around index: Int) {
        guard previewsEnabled, #available(macOS 14, *), previewTask == nil else { return }
        let current = request
        let indices = [index, index - 1, index + 1, index - 2, index + 2]
            .filter { cards[$0] != nil && !attempted.contains($0) }
        guard !indices.isEmpty, attempted.count < 12 else { return }
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.request == current {
                    self.previewTask = nil
                    if self.selected != index { self.loadPreviews(around: self.selected) }
                }
            }
            let cached = self.previewSource as? WindowPreviewSource
            let source: WindowPreviewSource?
            if let cached { source = cached } else { source = await WindowPreviewSource.load() }
            guard self.request == current, let source else { return }
            self.previewSource = source
            for candidate in indices {
                guard !Task.isCancelled, self.request == current, self.attempted.count < 12 else { break }
                self.attempted.insert(candidate)
                if let image = await source.image(for: self.windows[candidate]),
                   self.request == current, !Task.isCancelled {
                    self.cards[candidate]?.setPreview(image)
                }
            }
        }
    }

    var selectedWindow: SwitchWindow? { windows.indices.contains(selected) ? windows[selected] : nil }

    @objc func commit() {
        let chosen = selectedWindow
        cancel()
        guard let chosen, let app = NSRunningApplication(processIdentifier: chosen.target.pid),
              !app.isTerminated else { return }
        if app.isHidden { app.unhide() }
        let activated = app.activate(options: [.activateIgnoringOtherApps])
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard let operation, !operation.isCancelled else { return }
            if !activated && !app.isTerminated {
                AXUIElementSetAttributeValue(DesktopAccess.application(chosen.target.pid),
                                             kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            if !operation.isCancelled { DesktopAccess.raise(chosen) }
        }
        pendingFocus = operation
        queue.async { operation.start() }
    }

    @objc func cancel() {
        request = UUID()
        active = false
        isRendering = false
        userNavigated = false
        clearCards()
        windows.removeAll()
        selected = 0
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func clearCards() {
        previewTask?.cancel()
        previewTask = nil
        previewSource = nil
        attempted.removeAll()
        for card in cards.values { strip.removeArrangedSubview(card); card.removeFromSuperview() }
        cards.removeAll()
    }
}
