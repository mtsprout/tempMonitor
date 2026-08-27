# TempMonitor

A small native macOS app that graphs CPU temperature live, like Activity Monitor's CPU graph, with a menu bar widget and threshold alerts.

## Features

- Two stacked panes, rrdtool-style:
  - **Live** — last 5 minutes at full 1-second resolution
  - **History** — the last 24 hours as 5-minute averages, with its own color-coded average readout next to the pane label
- Dashed **yellow line at 85°C** and **red line at 95°C** in both panes — 85% and 95% of this Mac's CPU thermal max (see below)
- Line color, and the current/average readouts, shift green → yellow → red live based on temperature
- Menu bar icon drawn as a thermometer (tube + bulb) filled to the 5-minute rolling average, so it doesn't jitter every second; hover shows the live instantaneous reading; click brings the window to the front
- Alerts when a threshold is breached: a system notification, an audible chime, and an in-app banner — fires once per breach (not every second), with hysteresis so it won't spam while hovering near a line
- Window defaults to ~420×600 (to fit both panes) and is freely resizable, down to 320×480
- Closing the window just hides it; the menu bar widget and readings keep running in the background. Quit via Cmd+Q or the Dock/menu bar Quit.

## Why 85°C / 95°C

This app was built for an iMac20,2 (27", 2020) with an 8-core Intel Core i7-10700K. Intel's spec lists that chip's Tjunction max — the point at which it throttles or shuts down to protect itself — at **100°C** ([Intel ARK](https://www.intel.com/content/www/us/en/products/sku/199335/intel-core-i710700k-processor-16m-cache-up-to-5-10-ghz/specifications.html)). The thresholds are 85% and 95% of that ceiling. If you run this on different hardware, update `ThermalSpec.tjMax` in `main.swift` to match your CPU's Tjunction max.

## Requirements

- macOS
- Xcode Command Line Tools (for `swiftc`)
- [`osx-cpu-temp`](https://github.com/lavoiesl/osx-cpu-temp), installed via Homebrew:

  ```
  brew install osx-cpu-temp
  ```

  This reads the SMC temperature sensor directly and doesn't require sudo. The app shells out to `/usr/local/bin/osx-cpu-temp -c` once per second.

## Build

```
swiftc -O main.swift -o TempMonitor
```

## Package as an app bundle

```
mkdir -p TempMonitor.app/Contents/MacOS
cp TempMonitor TempMonitor.app/Contents/MacOS/TempMonitor
cp Info.plist TempMonitor.app/Contents/Info.plist
```

Re-run all three commands (build + both copies) after every change to `main.swift`, then:

```
open TempMonitor.app
```

The first launch will prompt for notification permission — allow it so threshold breaches show a system banner (the audible chime and in-app banner work either way).

## Project layout

- `main.swift` — the entire app (single file)
- `Info.plist` — app bundle metadata, copied into the bundle at package time
- `TempMonitor` (binary) and `TempMonitor.app/` (bundle) — build output, not tracked in git (see `.gitignore`)
