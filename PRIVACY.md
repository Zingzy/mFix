# Privacy

mFix collects nothing and sends nothing. It has no networking code at all: no telemetry, no analytics, no crash reporting, no update checks and no accounts. Everything below happens on your Mac and stays there.

## What each permission reads

**Accessibility.** mFix reads the position, size, title and state of windows, the Dock's icons, and which element has focus in Finder. It moves, resizes, minimizes, focuses and closes windows when you ask it to. It watches keyboard and mouse events to spot its own chords, title bar drags and file drags. In Finder it also swallows the keys it replaces and posts Finder's own keys in their place. It does not store what you type. The developer switch `MFIX_DEBUG` writes key codes of mFix's shortcuts, app names and window titles to the system log. It is off unless you start mFix with it set.

**Screen Recording.** mFix captures small images of your windows for the switcher, Snap Assist and Dock previews, and a live picture of a pinned window for Always on Top. It also captures the desktop picture for Snap Assist's background. Images are taken only while one of these panels is open, kept in memory for the next time it opens, and never written to disk.

**Automation for Finder.** When Cmd+V moves files into a selected folder, mFix asks Finder for the front window's folder and the selected items, then asks Finder to move the files. It does nothing else with Finder's scripting access.

## What mFix stores

Your settings, in `~/Library/Preferences/dev.zingzy.mfix.plist`. mFix also saves there whether the system Cmd+Tab and Cmd+Option+D shortcuts were on before it turned them off, so it can put them back.

Launch at login is registered with macOS and shows in System Settings, General, Login Items.

Nothing else is written anywhere.

## Checking for yourself

The source is all here. Search it for networking and you will find none:

```sh
grep -rnE 'URLSession|NWConnection|import Network|http' Sources
```
