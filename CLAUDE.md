# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

A single-file SwiftUI macOS app (`main.swift`) that graphs live CPU temperature and mirrors it in a menu bar widget. No Xcode project — built directly with `swiftc`. See `README.md` for user-facing build/run instructions; this file is about how the code is put together and how to iterate on it.

## Build and run loop

```
swiftc -O main.swift -o TempMonitor
cp TempMonitor TempMonitor.app/Contents/MacOS/TempMonitor
cp Info.plist TempMonitor.app/Contents/Info.plist   # only needed if Info.plist changed
pkill -f "TempMonitor.app/Contents/MacOS/TempMonitor"   # if already running
open TempMonitor.app
```

`swiftc -O main.swift -o TempMonitor` alone is enough to catch compile errors while iterating — only rebuild the `.app` bundle and relaunch when you want to see it run.

There is no test suite. Verifying behavior means actually launching the app and checking `ps aux | grep TempMonitor` for a live, non-crashing process, since automated screenshotting (`screencapture`, `osascript` UI scripting) hangs waiting on a screen-recording/accessibility permission dialog that can't be clicked through headlessly — don't burn time retrying that; report what you can verify and let the user eyeball the rest.

## Architecture

Everything lives in `main.swift`, organized by `// MARK:` sections:

- **`ThermalSpec`** — the single source of truth for temperature thresholds (`tjMax`, derived `yellow`/`red`, chart floor/ceiling). This app targets an iMac20,2 (i7-10700K, Tjmax 100°C per Intel ARK). If this ever runs on different hardware, this is the only place that needs to change.
- **`TemperatureReader`** — an `ObservableObject` singleton (`TemperatureReader.shared`). Owns the 1s polling `Timer`, threshold-crossing alert state, and an `onSample` closure hook the menu bar widget uses to redraw its icon. History is kept rrdtool-style across two buffers (sizes defined once in `HistorySpec`): `rawHistory` holds the last 5 minutes at full 1s resolution; `bucketHistory` holds up to 35 five-minute averages (175 minutes) behind that, for 3 hours total. Samples evicted from `rawHistory` feed a running accumulator that finalizes into one `bucketHistory` entry every 300 evicted samples — buckets only ever cover time strictly older than the raw window, so there's no overlap. It's a singleton and started exactly once, from `AppDelegate.applicationDidFinishLaunching`, specifically so polling and alerting keep running even when the SwiftUI window is closed/hidden — don't move `.start()` back into a view's `onAppear`, that ties the timer to view lifecycle and breaks the "window closed but menu bar still works" behavior.
- **`AppDelegate`** — bridges to AppKit for things SwiftUI's `WindowGroup` doesn't expose: the `NSStatusItem` (menu bar icon + live sparkline rendered by hand with `NSBezierPath` inside `lockFocus`/`unlockFocus`), intercepting the window's close button via `NSWindowDelegate.windowShouldClose` to hide (`orderOut`) instead of destroy the window, and `applicationShouldTerminateAfterLastWindowClosed` returning `false` so the app (and its menu bar icon) survives the window closing. Exposed as `AppDelegate.shared` (set in `init()`) because SwiftUI's `@NSApplicationDelegateAdaptor` owns the instance and there's no other clean way to reach it from a `View`.
- **`WindowAccessor`** — a one-off `NSViewRepresentable` used purely to get a handle on the `NSWindow` hosting `ContentView`, so it can be handed to `AppDelegate.attach(window:)`. `NSApp.windows.first` was considered and rejected as fragile if more windows are ever added.
- **`TemperatureChart`** / **`ContentView`** — the visible graph and surrounding chrome (current/max readout, threshold legend, alert banner). Reads `ThermalSpec` for scaling and threshold lines so the chart and the menu bar icon never disagree about what "yellow" or "red" means. Plots `bucketHistory` then `rawHistory` as one continuous line with x positions weighted by actual elapsed time (`HistorySpec.bucketSeconds` per bucket, 1s per raw sample) rather than equal index spacing — that's what makes the 5-minute raw segment a dense sliver at the right edge and the 3-hour bucket segment the bulk of the width, matching real rrdtool graphs. `TimeAxisLabels` mirrors this with a `totalSeconds` (not sample-count) input for the same reason.

## Conventions and constraints to preserve

- Keep this a single file unless it grows enough to justify splitting — it's intentionally a small, self-contained utility, not a full Xcode project.
- Alerts (`checkThresholds`/`fireAlert` in `TemperatureReader`) are edge-triggered with hysteresis (`resetMargin`): a breach fires once, and won't fire again until the reading drops a couple degrees back below yellow. Don't change this to fire on every sample above a threshold — that was an explicit fix, not an oversight.
- Alerts intentionally layer three independent channels (`UNUserNotificationCenter` banner, `NSSound` chime, in-app banner) because the system notification permission is easy to deny or miss on first launch for an ad-hoc, unsigned `.app`; don't remove the sound/in-app fallbacks on the assumption the OS banner alone is enough.
- The app depends on the external `osx-cpu-temp` CLI (installed via Homebrew, path hardcoded as `/usr/local/bin/osx-cpu-temp`) rather than reading SMC keys directly in-process. That trade was deliberate: `osx-cpu-temp` already encodes the correct SMC sensor key selection across Mac models, and reimplementing that in Swift risks silently reading the wrong sensor.
- No dependency manager, no Package.swift — plain `swiftc`. Don't introduce SwiftPM/Xcode project scaffolding unless asked; it's not needed for a single-file app.
