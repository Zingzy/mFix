# Security

## Reporting a problem

Report security problems privately through GitHub. Open this repository's Security tab and click "Report a vulnerability". Please don't open a public issue for them.

Say which mFix and macOS versions you saw it on, and how to reproduce it. Replies come on the report, and fixes ship in a new release.

## Supported versions

Only the latest release gets fixes.

## What counts

mFix runs with Accessibility and Screen Recording permission and watches keyboard and mouse events. These are worth reporting:

- Anything that lets another app or a web page drive mFix, or read what it sees.
- Window contents or keystrokes ending up anywhere outside mFix's memory.
- A way to leave the system Cmd+Tab or Cmd+Option+D switched off after mFix quits.
- Finder moving, trashing or deleting files you didn't select.
