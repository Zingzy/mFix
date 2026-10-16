# Terms of use

mFix is free software under the [MIT License](LICENSE). It comes as is, with no warranty of any kind. You use it at your own risk.

A few things to know before you do:

- mFix calls private macOS functions for things the public API can't do, like capturing minimized windows, bringing one window of another app forward and switching system shortcuts. A macOS update can break any of them without notice.
- While it runs, mFix turns off the system Cmd+Tab and Cmd+Shift+Tab, and Cmd+Option+D when Win is Cmd+Option. It puts them back when it quits or crashes. If it was force killed, it puts them back the next time it starts, so open it once and quit it from its menu.
- The Finder keys move, trash and delete real files. Shift+Delete deletes for good after Finder asks you.
- mFix is not affiliated with, endorsed by or sponsored by Microsoft or Apple.
