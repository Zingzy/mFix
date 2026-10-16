# Changelog

All notable changes to mFix are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [0.1.1] - 2026-10-17

### Fixed

- mFix froze for seconds at a time when any app was slow to answer Accessibility, as Caffeine and some WebKit helpers are. Snap Assist hung, Cmd+Tab took up to 3 s to open, and drags and Dock spring loading were missed. Every Accessibility call now gives up after 0.3 s, apps are asked at once instead of one by one, and an app that stops answering is skipped until it answers again. Listing windows went from 1.5 s to under 10 ms.
- Cmd+Tab no longer waits on apps macOS napped while you were away. It shows their last known windows and catches up in the background.

### Changed

- Dock window previews show the moment you hover an icon. The delay is still in Settings.

## [0.1.0] - 2026-10-16

The first public release. Requires macOS 26.

### Snapping

- Win+Arrow with the Windows 11 rules: halves, quarters, maximize, restore and minimize, across monitors.
- Win+Shift+Arrow to move a window to the next monitor, stretch it to full height or restore it, and Cmd+Option+Ctrl+Up or Down for the top or bottom half.
- Snap Layouts on hovering the green button, and on Win+Z with number badges. Suggested layouts built from the windows you have open.
- Snap Assist fills the rest of the screen after a snap.
- Drag a window to an edge or corner to snap it.
- Snap groups, and a divider handle on any line where snapped windows touch.

### Switcher

- Cmd+Tab shows the Windows 11 Alt+Tab: one card per window, live thumbnails, windows from every Space, snap groups as one card, close buttons, and Cmd+Ctrl+Tab to keep it open.
- Works while dragging files.

### Desktop and Dock

- Win+Home and Win+D, both toggles. Win+1 to 9 for the Dock's apps. Cmd+Shift+Esc opens Activity Monitor.
- Hover a Dock icon to see its windows. Click the app in front to minimize it or step through its windows.
- A preview of what you drag, and Dock spring loading.

### Finder

- Enter opens, F2 renames, Delete trashes, Shift+Delete deletes for good, Cmd+X then Cmd+V moves, Cmd+L goes to a path, Cmd+Option+T opens a terminal.

### Always on Top

- Cmd+Option+Ctrl+T pins a window above the others, with an accent border.

### Settings

- A settings window with a switch for every feature, and launch at login.

[0.1.1]: https://github.com/Zingzy/mFix/releases/tag/v0.1.1
[0.1.0]: https://github.com/Zingzy/mFix/releases/tag/v0.1.0
