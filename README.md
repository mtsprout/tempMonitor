# TempMonitor

A small native macOS app that graphs CPU temperature live, like Activity Monitor's CPU graph, with a menu bar widget and threshold alerts.

## Features

- Two stacked panes, rrdtool-style:
  - **Live** — last 5 minutes at full 1-second resolution
  - **Range** — a selectable window (1 Hour, 12 Hours, 24 Hours, 1 Week, 30 Days, or 1 Year) with a color-coded average readout next to the pane label, backed by a local SQLite database so history survives app restarts and crashes. Point resolution scales with the window: 5-minute averages for the three shortest ranges, hourly for 1 Week/30 Days, daily for 1 Year. Each range always spans its full window with the newest data on the right; periods with no recorded data are left blank at the edges (so a fresh 1 Year view is mostly empty) and bridged with a straight line between real samples
- Dashed **yellow line at 85°C** and **red line at 95°C** in both panes — 85% and 95% of this Mac's CPU thermal max (see below)
- Line color, and the current/average readouts, shift green → yellow → red live based on temperature
- Menu bar icon drawn as a thermometer (tube + bulb) filled to the 5-minute rolling average, so it doesn't jitter every second; hover shows the live instantaneous reading; click brings the window to the front
- Alerts when a threshold is breached: a system notification, an audible chime, and an in-app banner — fires once per breach (not every second), with hysteresis so it won't spam while hovering near a line
- Window defaults to ~420×640 (to fit both panes) and is freely resizable, down to 320×520
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

Uses macOS's built-in SQLite3 (`import SQLite3`) for durable history storage — this links automatically via the SDK's module map, no extra build flags needed.

## Package as an app bundle

```
mkdir -p TempMonitor.app/Contents/MacOS TempMonitor.app/Contents/Resources
cp TempMonitor TempMonitor.app/Contents/MacOS/TempMonitor
cp Info.plist TempMonitor.app/Contents/Info.plist
cp AppIcon.icns TempMonitor.app/Contents/Resources/AppIcon.icns
```

Re-run all four commands (build + three copies) after every change to `main.swift`, then:

```
open TempMonitor.app
```

The first launch will prompt for notification permission — allow it so threshold breaches show a system banner (the audible chime and in-app banner work either way).

### Installing to /Applications

```
cp -R TempMonitor.app /Applications/TempMonitor.app
```

If you change the icon after installing, macOS's icon cache can be stubborn about picking up the update — `touch /Applications/TempMonitor.app` and relaunching Finder/Dock (`killall Finder Dock`) forces a refresh.

### Regenerating the icon

`AppIcon.icns` (checked into the repo) is built from a hand-drawn PNG, using the same tube-and-bulb drawing approach as the menu bar icon (see `AppDelegate.updateIcon` in `main.swift`), just larger and with a fixed 67°C reading. To change the design, edit `make_icon.swift`, then:

```
swift make_icon.swift   # writes AppIcon.png (gitignored, intermediate)
mkdir -p AppIcon.iconset
sips -z 16 16   AppIcon.png --out AppIcon.iconset/icon_16x16.png
sips -z 32 32   AppIcon.png --out AppIcon.iconset/icon_16x16@2x.png
sips -z 32 32   AppIcon.png --out AppIcon.iconset/icon_32x32.png
sips -z 64 64   AppIcon.png --out AppIcon.iconset/icon_32x32@2x.png
sips -z 128 128 AppIcon.png --out AppIcon.iconset/icon_128x128.png
sips -z 256 256 AppIcon.png --out AppIcon.iconset/icon_128x128@2x.png
sips -z 256 256 AppIcon.png --out AppIcon.iconset/icon_256x256.png
sips -z 512 512 AppIcon.png --out AppIcon.iconset/icon_256x256@2x.png
sips -z 512 512 AppIcon.png --out AppIcon.iconset/icon_512x512.png
cp AppIcon.png AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

## Project layout

- `main.swift` — the entire app (single file)
- `Info.plist` — app bundle metadata, copied into the bundle at package time
- `make_icon.swift` — one-off script that draws `AppIcon.png`, the source for `AppIcon.icns`
- `AppIcon.icns` — the compiled app icon, copied into the bundle's `Resources/` at package time; tracked in git (the intermediate `AppIcon.png` and `AppIcon.iconset/` are not, see `.gitignore`)
- `TempMonitor` (binary) and `TempMonitor.app/` (bundle) — build output, not tracked in git (see `.gitignore`)
- `~/Library/Application Support/TempMonitor/history.sqlite` — durable 5-minute bucket history, created on first launch, retained for 1 year and pruned automatically; not tracked in git
