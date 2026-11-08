// SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Carbon
import IOKit.hidsystem

enum RightCommandMode: Int {
    case doubleHold
    case singleHold
    case tap
}

struct CommandGesture {
    private var firstPress: TimeInterval?
    private var secondPress = false
    private var pressed = false

    mutating func update(down: Bool, time: TimeInterval, singleHold: Bool = false) -> Bool {
        guard pressed != down else { return false }
        pressed = down
        if down {
            if singleHold { return true }
            if let firstPress, time - firstPress < 0.4 {
                self.firstPress = nil
                secondPress = true
                return true
            }
            firstPress = time
        } else if secondPress {
            reset()
        }
        return false
    }

    mutating func reset() {
        firstPress = nil
        secondPress = false
        pressed = false
    }
}

final class GlobalKeys {
    var onClipboard: (() -> Void)?
    var onCycle: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCommandTap: (() -> Void)?
    var onCommandHold: (() -> Void)?
    var onCommandEnd: (() -> Void)?
    var commandMode: RightCommandMode = .doubleHold
    var commandHoldDelay: TimeInterval = 0.2
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = CommandGesture()
    private var rightTapArmed = false
    private var hold: DispatchWorkItem?
    private var switchExpiry: DispatchWorkItem?
    private var switching = false
    private var reading = false
    private var clipboardKey = false
    private var windowKeys = false
    private var shortcutKeys = false

    func configure(windows: Bool, shortcuts: Bool, clipboard: Bool) -> Bool {
        stop()
        windowKeys = windows
        shortcutKeys = shortcuts
        clipboardKey = clipboard
        guard windows || shortcuts || clipboard else { return true }
        let events: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                               | (1 << CGEventType.flagsChanged.rawValue)
        func eventTap(at location: CGEventTapLocation) -> CFMachPort? {
            CGEvent.tapCreate(tap: location, place: .headInsertEventTap,
                              options: windows || clipboard ? .defaultTap : .listenOnly,
                              eventsOfInterest: events, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let observer = Unmanaged<GlobalKeys>.fromOpaque(pointer).takeUnretainedValue()
                return observer.handle(type, event: event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        }
        let earlyTap = windows ? eventTap(at: .cghidEventTap) : nil
        guard let tap = earlyTap ?? eventTap(at: .cgSessionEventTap),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        reset()
    }

    private func endShortcutDisplay() {
        hold?.cancel()
        hold = nil
        if reading { onCommandEnd?() }
        reading = false
    }

    private func reset() {
        endShortcutDisplay()
        switchExpiry?.cancel()
        gesture.reset()
        rightTapArmed = false
        if switching { onCancel?() }
        switching = false
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let modifiers = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged {
            if switching {
                if !modifiers.contains(.maskCommand) {
                    switching = false
                    switchExpiry?.cancel()
                    DispatchQueue.main.async { [weak self] in self?.onCommit?() }
                }
                return false
            }
            guard shortcutKeys else { return false }
            let leftCommandDown = event.flags.rawValue & UInt64(NX_DEVICELCMDKEYMASK) != 0
            let rightOnly = modifiers == [.maskCommand] && !leftCommandDown
            guard key == kVK_RightCommand, (modifiers.isEmpty || rightOnly), !IsSecureEventInputEnabled() else {
                endShortcutDisplay()
                gesture.reset()
                rightTapArmed = false
                return false
            }
            if commandMode == .tap {
                if rightOnly {
                    rightTapArmed = true
                } else if rightTapArmed {
                    rightTapArmed = false
                    DispatchQueue.main.async { [weak self] in self?.onCommandTap?() }
                }
                return false
            }
            if !rightOnly { endShortcutDisplay() }
            if gesture.update(down: rightOnly, time: ProcessInfo.processInfo.systemUptime,
                              singleHold: commandMode == .singleHold) {
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.hold = nil
                    self.reading = true
                    self.onCommandHold?()
                }
                hold = item
                DispatchQueue.main.asyncAfter(deadline: .now() + commandHoldDelay, execute: item)
            }
            return false
        }
        guard type == .keyDown else { return false }
        rightTapArmed = false
        endShortcutDisplay()
        gesture.reset()
        if clipboardKey, key == kVK_ANSI_V, modifiers == [.maskControl, .maskAlternate] {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in self?.onClipboard?() }
            }
            return true
        }
        if windowKeys, key == kVK_Tab,
           modifiers == [.maskCommand] || modifiers == [.maskCommand, .maskShift] {
            switching = true
            switchExpiry?.cancel()
            let expiry = DispatchWorkItem { [weak self] in
                guard let self, self.switching else { return }
                self.switching = false
                self.onCancel?()
            }
            switchExpiry = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: expiry)
            let step = modifiers.contains(.maskShift) ? -1 : 1
            DispatchQueue.main.async { [weak self] in self?.onCycle?(step) }
            return true
        }
        if switching, key == kVK_LeftArrow || key == kVK_RightArrow {
            let step = key == kVK_LeftArrow ? -1 : 1
            DispatchQueue.main.async { [weak self] in self?.onCycle?(step) }
            return true
        }
        if switching, key == kVK_Escape || key == kVK_Return {
            switching = false
            switchExpiry?.cancel()
            DispatchQueue.main.async { [weak self] in
                if key == kVK_Escape { self?.onCancel?() } else { self?.onCommit?() }
            }
            return true
        }
        return false
    }
}
