// SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import ServiceManagement

private let appName = "الخدمات المساعدة"

final class UtilitiesApp: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private enum Preference {
        static let recording = "ClipboardRecording"
        static let commandTab = "CommandTab"
        static let commandHold = "CommandHold"
        static let commandMode = "RightCommandGesture"
        static let legacySingleCommandHold = "SingleRightCommandHold"
        static let commandHoldDelay = "RightCommandHoldDelay"
        static let clipboardKey = "ClipboardShortcut"
        static let previews = "WindowPreviews"
    }

    private enum Section: Int {
        case clipboard, notes, shortcuts, windows
    }

    private let preferences: UserDefaults
    private let store: LocalStore
    private let history: ClipboardHistory
    private let keys = GlobalKeys()
    private let popover = NSPopover()
    private let shortcutQueue = DispatchQueue(label: "helpful.shortcut-access", qos: .userInitiated)
    private var statusItem: NSStatusItem?
    private var shell: NSStackView?
    private var tabBar: NSSegmentedControl?
    private var body: NSView?
    private var section: Section = .clipboard
    private var shortcutRequest = UUID()
    private var holdRequest = UUID()
    private var holdBusy = false
    private var previousApp: NSRunningApplication?
    private var clipboardDestination: NSRunningApplication?
    private var recentApps: [pid_t] = []
    private var appChanges: NSObjectProtocol?
    private var activeChanges: NSObjectProtocol?
    private var keysInstalled = false
    private var currentKeyConfig: (Bool, Bool, Bool)?
    private var demoWindow: NSWindow?
    private var notes: NotesPane?
    private var clipboard: ClipPane?
    private var shortcuts: ShortcutBoard?
    private var shortcutOverlay: NSPanel?
    private var switcher: WindowSwitcher?
    private var clipboardProblem = false
    private let testMode: Bool
    private let benchmarkMode: Bool

    init(testMode: Bool, benchmarkMode: Bool) {
        self.testMode = testMode
        self.benchmarkMode = benchmarkMode
        if testMode || benchmarkMode {
            store = LocalStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("HelpfulUtilitiesUITest-\(UUID().uuidString)"))
            preferences = UserDefaults(suiteName: "HelpfulUtilitiesUITest") ?? .standard
            let board = NSPasteboard.withUniqueName()
            history = ClipboardHistory(board: board, store: store)
            if testMode {
                for label in ["https://developer.apple.com/documentation/appkit",
                              "تنظيم الأفكار قبل اجتماع الفريق",
                              "مسودة البريد — النسخة النهائية",
                              "Design review · Friday at 10:30",
                              "ملاحظات المشروع والخطوات التالية"] {
                    board.clearContents()
                    board.setString(label, forType: .string)
                    history.poll()
                }
            }
        } else {
            store = .standard
            preferences = .standard
            history = ClipboardHistory(store: store)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !testMode, !benchmarkMode {
            preferences.register(defaults: [Preference.commandTab: true, Preference.clipboardKey: true])
        }
        installEditMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = symbol("square.grid.2x2")
        item.button?.toolTip = "الخدمات المساعدة — الحافظة والملاحظات والاختصارات"
        item.button?.setAccessibilityLabel(appName)
        item.button?.target = self
        item.button?.action = #selector(statusPressed(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        popover.behavior = .transient
        popover.delegate = self

        history.onChange = { [weak self] in self?.refreshClipboard() }
        history.onError = { [weak self] _ in self?.clipboardProblem = true }
        history.setRecording(benchmarkMode || preferences.bool(forKey: Preference.recording))
        previousApp = NSWorkspace.shared.frontmostApplication
        appChanges = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            self.previousApp = app
            self.recentApps.removeAll { $0 == app.processIdentifier }
            self.recentApps.insert(app.processIdentifier, at: 0)
            if self.recentApps.count > 40 { self.recentApps.removeLast() }
        }
        activeChanges = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.installKeys() }
        keys.onClipboard = { [weak self] in self?.toggleClipboard() }
        keys.onCycle = { [weak self] step in self?.showWindows(step: step) }
        keys.onCommit = { [weak self] in self?.switcher?.commit() }
        keys.onCancel = { [weak self] in self?.switcher?.cancel() }
        keys.onCommandTap = { [weak self] in self?.toggleShortcutPage() }
        keys.onCommandHold = { [weak self] in self?.showShortcutOverlay() }
        keys.onCommandEnd = { [weak self] in self?.hideShortcutOverlay() }
        installKeys()

        if testMode {
            let model = NoteStore(store: store)
            try? model.save("أفكار للمشروع\n\nراجع **التصميم** يوم الأحد.\nابدأ بالملاحظات السريعة.", at: 0)
            openSection(.clipboard)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if notes?.flush() == false {
            alert("تعذّر حفظ الملاحظة", detail: "انسخ النص من المحرر قبل إغلاق التطبيق.")
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        keys.stop()
        history.setRecording(false)
        if let appChanges { NSWorkspace.shared.notificationCenter.removeObserver(appChanges) }
        if let activeChanges { NotificationCenter.default.removeObserver(activeChanges) }
        if testMode || benchmarkMode { try? FileManager.default.removeItem(at: store.directory) }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool { notes?.flush() != false }
    func windowShouldClose(_ sender: NSWindow) -> Bool { notes?.flush() != false }

    private func installEditMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "إنهاء \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "تحرير")
        for (name, action, key) in [
            ("تراجع", "undo:", "z"), ("إعادة", "redo:", "Z"),
            ("قص", "cut:", "x"), ("نسخ", "copy:", "c"),
            ("لصق", "paste:", "v"), ("تحديد الكل", "selectAll:", "a")
        ] {
            edit.addItem(withTitle: name, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        for menu in [appMenu, edit] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    @objc private func statusPressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showSettings(sender)
        } else {
            toggleClipboard()
        }
    }

    private func toggleClipboard() {
        if popover.isShown, section == .clipboard { popover.performClose(nil); return }
        openSection(.clipboard)
    }

    private func toggleShortcutPage() {
        if popover.isShown, section == .shortcuts { popover.performClose(nil); return }
        openSection(.shortcuts)
    }

    private func createShell() -> NSStackView {
        if let shell { return shell }
        let tabs = NSSegmentedControl(labels: ["الحافظة", "الملاحظات", "الاختصارات", "النوافذ"],
                                      trackingMode: .selectOne, target: self, action: #selector(selectTab(_:)))
        tabs.segmentStyle = .rounded
        tabs.controlSize = .regular
        for (i, image) in ["clipboard", "note.text", "keyboard", "rectangle.on.rectangle"].enumerated() {
            tabs.setImage(symbol(image, size: 12), forSegment: i)
            tabs.setImageScaling(.scaleProportionallyDown, forSegment: i)
            tabs.setToolTip(tabs.label(forSegment: i), forSegment: i)
        }
        let gear = iconButton("gearshape", title: "إعدادات الخدمات المساعدة", target: self, action: #selector(showSettings(_:)))
        gear.contentTintColor = .secondaryLabelColor
        gear.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let top = row([tabs, NSView(), gear])
        top.alignment = .centerY
        top.edgeInsets = .init(top: 12, left: 13, bottom: 7, right: 13)
        let body = NSView()
        let shell = column([top, NSBox.separator(), body], insets: 0)
        shell.spacing = 0
        self.shell = shell
        tabBar = tabs
        self.body = body
        return shell
    }

    @objc private func selectTab(_ sender: NSSegmentedControl) {
        guard let selection = Section(rawValue: sender.selectedSegment) else { return }
        if selection == .windows {
            sender.selectedSegment = section.rawValue
            popover.performClose(nil)
            showWindows(step: nil)
        } else {
            openSection(selection)
        }
    }

    private func openSection(_ selection: Section) {
        guard notes?.flush() != false else { tabBar?.selectedSegment = section.rawValue; return }
        let target = frontmost().map(AppTarget.init)
        let shell = createShell()
        guard let body else { return }
        let content: NSView
        let size: NSSize
        switch selection {
        case .clipboard:
            clipboardDestination = frontmost()
            if clipboard == nil {
                let view = ClipPane()
                view.choose = { [weak self] clip in
                    guard let self else { return }
                    self.history.copy(clip)
                    self.popover.performClose(nil)
                    if !self.testMode { self.clipboardDestination?.activate() }
                }
                view.remove = { [weak self] clip in self?.history.remove(clip) }
                view.startRecording = { [weak self] in self?.toggleRecording() }
                view.dismiss = { [weak self] in self?.popover.performClose(nil) }
                clipboard = view
            }
            guard let clipboard else { return }
            refreshClipboard()
            content = clipboard
            size = .init(width: 460, height: 405)
        case .notes:
            if notes == nil { notes = NotesPane(model: NoteStore(store: store)) }
            guard let notes else { return }
            content = notes
            size = .init(width: 460, height: 420)
        case .shortcuts:
            if shortcuts == nil { shortcuts = makeShortcutBoard(transient: false) }
            guard let shortcuts else { return }
            shortcuts.search.stringValue = ""
            loadShortcutPage(target: target, view: shortcuts)
            content = shortcuts
            size = .init(width: 562, height: 481)
        case .windows:
            return
        }
        section = selection
        tabBar?.selectedSegment = selection.rawValue
        if content.superview !== body {
            body.subviews.forEach { $0.removeFromSuperview() }
            fill(content, in: body)
        }
        if testMode {
            if demoWindow == nil {
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: true)
                window.title = appName
                window.isReleasedWhenClosed = false
                window.delegate = self
                window.contentView = shell
                window.center()
                demoWindow = window
            }
            demoWindow?.setContentSize(size)
            NSApp.activate(ignoringOtherApps: true)
            demoWindow?.makeKeyAndOrderFront(nil)
        } else if let anchor = statusItem?.button {
            if popover.contentViewController == nil {
                let controller = NSViewController()
                controller.view = shell
                popover.contentViewController = controller
            }
            popover.contentSize = size
            if !popover.isShown { popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY) }
            NSApp.activate(ignoringOtherApps: true)
            shell.window?.makeKey()
        }
        if selection == .clipboard { clipboard?.prepare() }
        if selection == .notes { notes?.focus() }
        if selection == .shortcuts { shortcuts?.window?.makeFirstResponder(shortcuts?.search) }
    }

    private func refreshClipboard() {
        clipboard?.update(history.clips, recording: preferences.bool(forKey: Preference.recording),
                          storageIssue: clipboardProblem)
    }

    private func frontmost() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { return front }
        return previousApp?.isTerminated == false ? previousApp : nil
    }

    @objc private func showSettings(_ sender: NSView) {
        installKeys()
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, checked: Bool? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let checked { item.state = checked ? .on : .off }
            menu.addItem(item)
        }
        add("تسجيل الحافظة النصية", #selector(toggleRecording), checked: preferences.bool(forKey: Preference.recording))
        add("فتح الحافظة بـ ⌃⌥V", #selector(toggleClipboardKey), checked: preferences.bool(forKey: Preference.clipboardKey))
        add("تبديل النوافذ بـ ⌘⇥", #selector(toggleCommandTab), checked: preferences.bool(forKey: Preference.commandTab))
        add("عرض الاختصارات بمفتاح ⌘ اليمين", #selector(toggleCommandHold),
            checked: preferences.bool(forKey: Preference.commandHold))
        addShortcutSettings(to: menu)
        if #available(macOS 14, *) {
            add("عرض صور مصغّرة للنوافذ", #selector(togglePreviews), checked: preferences.bool(forKey: Preference.previews))
        }
        if !keysInstalled || !DesktopAccess.allowed {
            add("إعداد أذونات macOS…", #selector(requestPermissions))
        }
        if #available(macOS 13, *), !testMode {
            add("فتح عند تسجيل الدخول", #selector(toggleLogin), checked: SMAppService.mainApp.status == .enabled)
        }
        menu.addItem(.separator())
        add("مسح سجل الحافظة…", #selector(clearClipboard))
        add("إنهاء التطبيق", #selector(quit))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    private var commandMode: RightCommandMode {
        if let value = preferences.object(forKey: Preference.commandMode) as? Int,
           let mode = RightCommandMode(rawValue: value) { return mode }
        if let previous = preferences.object(forKey: Preference.legacySingleCommandHold) as? Bool {
            return previous ? .singleHold : .doubleHold
        }
        return .tap
    }

    private var commandHoldDelay: TimeInterval {
        let stored = preferences.double(forKey: Preference.commandHoldDelay)
        return (0.2...2.0).contains(stored) ? stored : commandMode == .singleHold ? 1.0 : 0.2
    }

    private func addShortcutSettings(to menu: NSMenu) {
        let submenu = NSMenu()
        func option(_ title: String, action: Selector, tag: Int, selected: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = selected ? .on : .off
            submenu.addItem(item)
        }
        for (mode, label) in [(RightCommandMode.tap, "ضغطة واحدة ثم الإفلات"),
                              (.singleHold, "ضغطة مطوّلة واحدة"), (.doubleHold, "ضغطتان ثم الاستمرار")] {
            option(label, action: #selector(changeShortcutGesture(_:)), tag: mode.rawValue, selected: commandMode == mode)
        }
        if commandMode != .tap {
            submenu.addItem(.separator())
            for (milliseconds, label) in [(200, "0.2 ثانية"), (500, "0.5 ثانية"), (1000, "ثانية واحدة"), (2000, "ثانيتان")] {
                option(label, action: #selector(changeShortcutDelay(_:)), tag: milliseconds,
                       selected: Int((commandHoldDelay * 1000).rounded()) == milliseconds)
            }
        }
        let item = NSMenuItem(title: "طريقة عرض الاختصارات ومهلة الظهور", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    @objc private func changeShortcutGesture(_ item: NSMenuItem) {
        preferences.set(item.tag, forKey: Preference.commandMode)
        installKeys()
    }

    @objc private func changeShortcutDelay(_ item: NSMenuItem) {
        preferences.set(Double(item.tag) / 1000, forKey: Preference.commandHoldDelay)
        installKeys()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleRecording() {
        let enabled = !preferences.bool(forKey: Preference.recording)
        preferences.set(enabled, forKey: Preference.recording)
        history.setRecording(enabled)
        refreshClipboard()
    }

    @objc private func toggleClipboardKey() { toggleKey(Preference.clipboardKey) }
    @objc private func toggleCommandTab() { toggleKey(Preference.commandTab) }
    @objc private func toggleCommandHold() { toggleKey(Preference.commandHold) }

    private func toggleKey(_ key: String) {
        let enabled = !preferences.bool(forKey: key)
        preferences.set(enabled, forKey: key)
        installKeys()
        if enabled, !keysInstalled { requestPermissions() }
    }

    @objc private func requestPermissions() {
        if !DesktopAccess.allowed { DesktopAccess.request(); return }
        installKeys()
        if !keysInstalled {
            _ = CGRequestListenEventAccess()
            alert("تفعيل اختصارات لوحة المفاتيح",
                  detail: "اسمح للتطبيق ضمن الخصوصية والأمان ← مراقبة الإدخال، ثم أعد فتحه إذا طلب macOS ذلك.")
        }
    }

    @objc private func togglePreviews() {
        let enabled = !preferences.bool(forKey: Preference.previews)
        preferences.set(enabled, forKey: Preference.previews)
        if enabled, !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        switcher?.previewsEnabled = enabled
    }

    @available(macOS 13, *)
    @objc private func toggleLogin() {
        do {
            let service = SMAppService.mainApp
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            alert("تعذّر تغيير الفتح عند تسجيل الدخول", detail: error.localizedDescription)
        }
    }

    private func installKeys() {
        guard !testMode, !benchmarkMode else { return }
        keys.commandMode = commandMode
        keys.commandHoldDelay = commandHoldDelay
        let config = (preferences.bool(forKey: Preference.commandTab), preferences.bool(forKey: Preference.commandHold),
                      preferences.bool(forKey: Preference.clipboardKey))
        if !DesktopAccess.allowed, config.0 || config.1 || config.2 {
            if keysInstalled { keys.stop() }
            keysInstalled = false
            currentKeyConfig = nil
            return
        }
        if keysInstalled, let currentKeyConfig, currentKeyConfig == config { return }
        currentKeyConfig = config
        keysInstalled = keys.configure(windows: config.0, shortcuts: config.1, clipboard: config.2)
    }

    private func alert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "حسنًا")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func clearClipboard() {
        let confirm = NSAlert()
        confirm.messageText = "مسح سجل الحافظة؟"
        confirm.addButton(withTitle: "مسح")
        confirm.addButton(withTitle: "إلغاء")
        if confirm.runModal() == .alertFirstButtonReturn { history.clear() }
    }

    private func makeShortcutBoard(transient: Bool) -> ShortcutBoard {
        let view = ShortcutBoard(transient: transient)
        view.onDismiss = { [weak self] in self?.popover.performClose(nil) }
        view.onPrint = { [weak self] name, commands in
            guard let self else { return }
            self.hideShortcutOverlay()
            self.popover.performClose(nil)
            NSApp.activate(ignoringOtherApps: true)
            ShortcutPrinting.run(app: name, commands: commands)
        }
        return view
    }

    private func performShortcut(_ shortcut: Shortcut, target: AppTarget) {
        if let screenshot = shortcut.screenshot {
            hideShortcutOverlay()
            popover.performClose(nil)
            if let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated { _ = app.activate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                screenshot.run { message in self?.alert("لقطات الشاشة", detail: message) }
            }
            return
        }
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            alert("التطبيق مغلق", detail: "افتح التطبيق وأعد عرض قائمة اختصاراته.")
            return
        }
        hideShortcutOverlay()
        popover.performClose(nil)
        _ = app.activate()
        shortcutQueue.async { [weak self] in
            if !DesktopAccess.press(shortcut, in: target) {
                DispatchQueue.main.async {
                    self?.alert("تعذّر تنفيذ الأمر", detail: "قد تكون حالة قائمة التطبيق تغيّرت. افتح الاختصارات مرة أخرى.")
                }
            }
        }
    }

    private func loadShortcutPage(target: AppTarget?, view: ShortcutBoard) {
        let request = UUID()
        shortcutRequest = request
        view.onChoose = nil
        if testMode {
            view.onChoose = { [weak view] shortcut in
                view?.showStatus("تم اختيار أمر تجريبي: \(shortcut.title)")
            }
            view.update(app: "Finder", shortcuts: Self.sampleShortcuts, caption: "انقر على أمر لتنفيذه")
            return
        }
        guard DesktopAccess.allowed else {
            view.update(app: "اختصارات التطبيق", shortcuts: [], caption: "فعّل إذن التحكم من قائمة الإعدادات ⚙")
            return
        }
        guard let target else {
            view.update(app: "اختصارات التطبيق", shortcuts: [], caption: "افتح تطبيقًا ثم اختر الاختصارات.")
            return
        }
        view.update(app: target.name, shortcuts: [], caption: "جارٍ قراءة قوائم التطبيق…")
        loadShortcuts(target: target) { [weak self, weak view] commands in
            guard let self, self.shortcutRequest == request else { return }
            view?.onChoose = { [weak self] shortcut in self?.performShortcut(shortcut, target: target) }
            let caption = commands.isEmpty ? "ما ظهرت اختصارات في القوائم." : "\(commands.count) اختصار  ·  انقر على أمر لتنفيذه"
            view?.update(app: target.name, shortcuts: commands, caption: caption)
        }
    }

    private func loadShortcuts(target: AppTarget, completion: @escaping ([Shortcut]) -> Void) {
        shortcutQueue.async {
            let shortcuts = DesktopAccess.shortcuts(for: target) + ScreenshotShortcut.entries()
            DispatchQueue.main.async { completion(shortcuts) }
        }
    }

    private func showShortcutOverlay() {
        guard !holdBusy, let target = frontmost().map(AppTarget.init) else { return }
        let request = UUID()
        holdRequest = request
        holdBusy = true
        loadShortcuts(target: target) { [weak self] commands in
            guard let self else { return }
            self.holdBusy = false
            guard self.holdRequest == request else { return }
            let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 465),
                                      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.title = "اختصارات \(target.name)"
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            let view = self.makeShortcutBoard(transient: true)
            view.onChoose = { [weak self] shortcut in self?.performShortcut(shortcut, target: target) }
            view.update(app: target.name, shortcuts: commands,
                        caption: "انقر على أمر لتنفيذه  ·  أفلت ⌘ اليمين لإغلاق اللوحة")
            panel.contentView = view
            panel.center()
            panel.orderFrontRegardless()
            self.shortcutOverlay = panel
        }
    }

    private func hideShortcutOverlay() {
        holdRequest = UUID()
        shortcutOverlay?.orderOut(nil)
        shortcutOverlay = nil
    }

    private func showWindows(step: Int?) {
        if testMode {
            let targets = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.prefix(3)
            let titles = ["ملاحظات المشروع", "ملفات العمل", "نافذة الإعدادات"]
            windowSwitcher().displaySample(zip(targets, titles).map {
                SwitchWindow(target: AppTarget($0.0), element: nil, title: $0.1, minimized: false)
            })
            return
        }
        guard DesktopAccess.allowed else {
            if step == nil { requestPermissions() }
            return
        }
        popover.performClose(nil)
        let switcher = windowSwitcher()
        if let step, switcher.active { switcher.move(step); return }
        let front = frontmost()?.processIdentifier
        let ranking = ([front].compactMap { $0 } + recentApps).enumerated()
        var ranks: [pid_t: Int] = [:]
        for (index, pid) in ranking where ranks[pid] == nil { ranks[pid] = index }
        let targets = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid() }
            .map(AppTarget.init).sorted {
                let left = ranks[$0.pid] ?? Int.max
                let right = ranks[$1.pid] ?? Int.max
                return left == right ? $0.pid < $1.pid : left < right
            }
        switcher.previewsEnabled = preferences.bool(forKey: Preference.previews)
        switcher.show(targets: targets, step: step,
                      hasFrontWindowCandidate: front != nil && front == targets.first?.pid)
    }

    private func windowSwitcher() -> WindowSwitcher {
        if let switcher { return switcher }
        let view = WindowSwitcher()
        view.onFailure = { [weak self] in
            self?.alert("تعذّر فتح النافذة", detail: "جرّب اختيارها مرة أخرى إذا كانت لا تزال مفتوحة.")
        }
        switcher = view
        return view
    }

    private static let sampleShortcuts = [
        Shortcut(title: "نافذة Finder جديدة", group: "ملف", keys: "⌘N"),
        Shortcut(title: "فتح", group: "ملف", keys: "⌘O"),
        Shortcut(title: "إغلاق النافذة", group: "ملف", keys: "⌘W"),
        Shortcut(title: "عرض بالأيقونات", group: "عرض", keys: "⌘1"),
        Shortcut(title: "عرض كقائمة", group: "عرض", keys: "⌘2"),
        Shortcut(title: "التنزيلات", group: "انتقال", keys: "⌥⌘L"),
        Shortcut(title: "انتقال إلى مجلد", group: "انتقال", keys: "⇧⌘G"),
        Shortcut(title: "نسخ", group: "تحرير", keys: "⌘C"),
        Shortcut(title: "لصق", group: "تحرير", keys: "⌘V", enabled: false)
    ]
}
