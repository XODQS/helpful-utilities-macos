# Helpful Utilities · الخدمات المساعدة

A lightweight native macOS menu bar app that brings clipboard history, quick notes, app shortcuts, and window switching together. Built with Swift and AppKit. The interface is in Arabic.

## Features

- **Clipboard** — Search recent copied text from the menu bar or with Control–Option–V. Choose an item and paste it with Command–V. History can be paused or cleared.
- **Quick notes** — Seven locally saved notes, with Markdown preview and text import and export.
- **App shortcuts** — Tap and release Right Command to display the frontmost app's menu shortcuts. Search, select an enabled command, or print the list and save it as PDF. The gear menu offers alternative hold gestures and adjustable delays.
- **Window switcher** — Press Command–Tab to cycle windows, then release Command to switch. Press Shift to go backwards or Escape to cancel. Optional thumbnails show available windows.
- **Screenshots** — View enabled macOS screenshot shortcuts and open capture tools from the shortcuts panel.

## Compatibility

| Requirement | Support |
| --- | --- |
| Processor | Apple Silicon, including M1 and later. The build targets arm64. |
| Mac models | Apple Silicon MacBook Air, MacBook Pro, Mac mini, iMac, Mac Studio, and Mac Pro. |
| macOS | macOS 13 or later. Window thumbnails need macOS 14 or later. |
| Intel Macs | The provided build targets Apple Silicon. |
| Language | Arabic interface. |

Development and basic tests were performed on an M1 Mac. Other Apple Silicon models and macOS versions have not been individually tested.

## Setup and permissions

Move the built app to Applications before opening it. Click the four-square icon in the menu bar, then use the gear menu to enable clipboard recording and optional features.

- **Accessibility / Device Control and Data Access** is used to read app menus and switch windows.
- **Input Monitoring** may be requested for global keyboard shortcuts.
- **Screen Recording** is used for optional window previews and screenshot commands.

Clipboard history and notes are stored locally in the macOS user account. History keeps up to 80 text items and can be turned off. Notes do not sync through iCloud. App shortcuts depend on what each app exposes through its menus. Window and preview availability varies by app and workspace.

## Build from source

On an Apple Silicon Mac, install Xcode or Xcode Command Line Tools, then run from the repository root:

```sh
zsh ./build.sh "/private/tmp/Helpful Utilities.app"
"/private/tmp/Helpful Utilities.app/Contents/MacOS/HelpfulUtilities" --self-test
```

Choose a new output path if that app already exists. The build uses the system Swift compiler and Apple frameworks, and signs the output locally with an ad-hoc signature.

## العربية

**الخدمات المساعدة** يجمع الحافظة والملاحظات واختصارات التطبيقات وتبديل النوافذ في أيقونة واحدة. اضغط ⌘ اليمين وأفلته لعرض اختصارات التطبيق الأمامي، واستخدم ⌘⇥ للتنقل بين النوافذ. إعدادات التسجيل والأذونات والاختصارات متاحة من أيقونة الترس.

يستهدف التطبيق أجهزة ماك بمعالجات Apple Silicon ونظام macOS 13 أو أحدث. الملاحظات وسجل الحافظة محفوظان محليًا. جُرّبت الوظائف الأساسية على جهاز M1.

## License

Copyright (C) 2026 Helpful Utilities contributors.

Licensed under the GNU General Public License, version 2 only (`GPL-2.0-only`). See [LICENSE](LICENSE).
