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
        name.stringValue = window.target.name + (window.minimized ? "  ·  مصغّرة" : "")
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
    private var cards: [WindowCard] = []
    private var selected = 0
    private var request = UUID()
    private var loading = false
    private var pendingCommit = false
    private var offset = 0
    private var previewTask: Task<Void, Never>?
    private var attempted = Set<Int>()
    private var previewSource: Any?
    private let queue = DispatchQueue(label: "helpful.window-access", qos: .userInitiated)
    var previewsEnabled = false
    private(set) var active = false
    var onFailure: (() -> Void)?

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

    func show(targets: [AppTarget], step: Int?, hasFrontWindowCandidate: Bool) {
        if active, let step { move(step); return }
        cancel()
        active = true
        loading = true
        offset = step ?? 0
        caption.stringValue = "جارٍ قراءة النوافذ…"
        position(width: 440)
        if step == nil { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel) }
        else { panel.orderFrontRegardless() }
        let current = request
        queue.async { [weak self] in
            let available = DesktopAccess.windows(for: targets)
            DispatchQueue.main.async {
                guard let self, self.active, current == self.request else { return }
                self.loading = false
                let frontMatches = hasFrontWindowCandidate && available.first?.target.pid == targets.first?.pid
                let initial = step != nil && !frontMatches && self.offset > 0 ? self.offset - 1 : self.offset
                self.display(available, startingAt: initial)
                if self.pendingCommit { self.commit() }
            }
        }
    }

    func displaySample(_ sample: [SwitchWindow]) {
        cancel()
        active = true
        display(sample, startingAt: 1)
        panel.makeKeyAndOrderFront(nil)
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

    private func display(_ available: [SwitchWindow], startingAt initial: Int) {
        windows = available
        var icons: [pid_t: NSImage] = [:]
        for (index, window) in windows.enumerated() {
            let pid = window.target.pid
            if icons[pid] == nil { icons[pid] = NSRunningApplication(processIdentifier: pid)?.icon }
            let card = WindowCard(window: window, image: icons[pid])
            card.activate = { [weak self] in self?.select(index); self?.commit() }
            cards.append(card)
            strip.addArrangedSubview(card)
        }
        position(width: max(350, min(905, CGFloat(windows.count) * 175 + 26)))
        if windows.isEmpty { caption.stringValue = "ما ظهرت نوافذ متاحة للتبديل."; return }
        select(initial)
    }

    func move(_ amount: Int) {
        if loading { offset += amount; return }
        select(selected + amount)
    }

    private func select(_ index: Int) {
        guard !windows.isEmpty else { return }
        selected = (index % windows.count + windows.count) % windows.count
        for (index, card) in cards.enumerated() { card.highlight(index == selected) }
        strip.layoutSubtreeIfNeeded()
        strip.scrollToVisible(cards[selected].frame.insetBy(dx: -6, dy: 0))
        caption.stringValue = "\(selected + 1) من \(windows.count)   ·   التالي \u{2066}⇥\u{2069}   ·   السابق \u{2066}⇧⇥\u{2069}   ·   أفلت ⌘ للاختيار"
        loadPreviews(around: selected)
    }

    private func loadPreviews(around index: Int) {
        guard previewsEnabled, #available(macOS 14, *), previewTask == nil else { return }
        let current = request
        let indices = [index, index - 1, index + 1, index - 2, index + 2]
            .filter { windows.indices.contains($0) && !attempted.contains($0) }
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
                    self.cards[candidate].setPreview(image)
                }
            }
        }
    }

    @objc func commit() {
        if loading { pendingCommit = true; return }
        let chosen = windows.indices.contains(selected) ? windows[selected] : nil
        cancel()
        guard let chosen, chosen.element != nil else { return }
        queue.async { [weak self] in
            if !DesktopAccess.focus(chosen) { DispatchQueue.main.async { self?.onFailure?() } }
        }
    }

    @objc func cancel() {
        request = UUID()
        active = false
        loading = false
        pendingCommit = false
        previewTask?.cancel()
        previewTask = nil
        previewSource = nil
        attempted.removeAll()
        windows.removeAll()
        for card in cards { strip.removeArrangedSubview(card); card.removeFromSuperview() }
        cards.removeAll()
        selected = 0
        panel.orderOut(nil)
    }
}
