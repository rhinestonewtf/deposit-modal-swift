---
name: simulator
description: Use when tapping through the example app or the hosted page on an iOS simulator, e.g. to reproduce a sheet or bridge behaviour by hand.
---

# Driving the example on a simulator

Launching and passing configuration (`RHINESTONE_AUTO_OPEN`, `SIMCTL_CHILD_*`) is in `CLAUDE.md`;
this covers interacting once the sheet is up.

- **`simctl` cannot tap; `idb` can.** It needs the Python client (`pipx install fb-idb`) as well
  as `idb_companion`, which has no UI commands of its own.
- **`idb ui tap <x> <y>` takes points, not pixels.** Divide `xcrun simctl io booted screenshot`
  coordinates by the device scale (3 on an iPhone 16 Pro), or the tap lands elsewhere silently.
