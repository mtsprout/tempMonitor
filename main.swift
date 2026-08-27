import SwiftUI
import Foundation
import AppKit
import UserNotifications

// MARK: - Thermal spec
//
// This Mac is an iMac20,2 (27", 2020) with an 8-core Intel Core i7-10700K.
// Intel lists Tjunction max (the point at which the CPU throttles/shuts
// down to protect itself) at 100C for this chip.
// Source: https://www.intel.com/content/www/us/en/products/sku/199335/intel-core-i710700k-processor-16m-cache-up-to-5-10-ghz/specifications.html
enum ThermalSpec {
    static let tjMax: Double = 100.0
    static let yellow: Double = tjMax * 0.85 // 85.0
    static let red: Double = tjMax * 0.95    // 95.0
    static let chartFloor: Double = 30.0
    static let chartCeiling: Double = tjMax + 5.0
}

// MARK: - History retention (rrdtool-style multi-resolution)
//
// Last 5 minutes stay at full 1s resolution ("current"); everything older,
// back to 3 hours total, is consolidated into 5-minute averages so the
// chart can span hours without keeping tens of thousands of raw samples.
enum HistorySpec {
    static let rawCapacitySeconds = 300      // 5 minutes @ 1s
    static let bucketSeconds: Double = 300   // each bucket averages 5 minutes
    static let bucketCapacity = 35           // 35 * 5min = 175 minutes behind the raw window (+5 min raw = 3h)
}

// MARK: - Alerts

enum AlertLevel: Equatable {
    case none
    case warning // crossed yellow (85%)
    case critical // crossed red (95%)
}

// MARK: - Temperature reading

final class TemperatureReader: ObservableObject {
    // Owned by AppDelegate for the lifetime of the app, independent of
    // whether the window is open, so the menu bar icon keeps updating
    // even while the window is hidden.
    static let shared = TemperatureReader()

    @Published var rawHistory: [Double] = []      // last 5 minutes, full resolution
    @Published var bucketHistory: [Double] = []   // older, 5-minute averages, oldest first
    @Published var current: Double = 0
    @Published var maxSeen: Double = 0
    @Published var alertLevel: AlertLevel = .none

    // Notified on every sample so the menu bar icon can redraw itself.
    var onSample: ((Double, [Double]) -> Void)?

    private var timer: Timer?
    private let toolPath = "/usr/local/bin/osx-cpu-temp"

    // Accumulates raw samples evicted from rawHistory until there are
    // enough (5 minutes' worth) to consolidate into one bucket average.
    private var bucketSum = 0.0
    private var bucketCount = 0

    // Edge-triggered alert state: fires once per breach, resets once the
    // temperature drops a few degrees below the yellow line (hysteresis)
    // so a reading hovering right at the threshold doesn't spam alerts.
    private var yellowAlerted = false
    private var redAlerted = false
    private let resetMargin = 2.0

    func start() {
        guard timer == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        readOnce()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.readOnce()
        }
    }

    private func readOnce() {
        guard let value = Self.readTemperature(toolPath: toolPath) else { return }
        DispatchQueue.main.async {
            self.current = value
            self.maxSeen = max(self.maxSeen, value)

            self.rawHistory.append(value)
            if self.rawHistory.count > HistorySpec.rawCapacitySeconds {
                // The sample aging out of the raw window feeds the
                // in-progress bucket — never the newly-arrived one, so
                // buckets only ever cover time strictly older than the
                // raw window (no overlap/double-counting).
                let evicted = self.rawHistory.removeFirst()
                self.bucketSum += evicted
                self.bucketCount += 1
                if self.bucketCount >= Int(HistorySpec.bucketSeconds) {
                    self.bucketHistory.append(self.bucketSum / HistorySpec.bucketSeconds)
                    if self.bucketHistory.count > HistorySpec.bucketCapacity {
                        self.bucketHistory.removeFirst()
                    }
                    self.bucketSum = 0
                    self.bucketCount = 0
                }
            }

            self.checkThresholds(value)
            self.onSample?(value, self.rawHistory)
        }
    }

    private func checkThresholds(_ value: Double) {
        if value >= ThermalSpec.red {
            alertLevel = .critical
            if !redAlerted {
                redAlerted = true
                yellowAlerted = true
                fireAlert(
                    title: "🔴 CPU Overheating",
                    body: String(format: "CPU temperature is %.1f°C — at or above the 95°C critical threshold.", value)
                )
            }
        } else if value >= ThermalSpec.yellow {
            alertLevel = .warning
            if !yellowAlerted {
                yellowAlerted = true
                fireAlert(
                    title: "⚠️ CPU Running Hot",
                    body: String(format: "CPU temperature is %.1f°C — above the 85°C warning threshold.", value)
                )
            }
        } else {
            alertLevel = .none
            if value < ThermalSpec.yellow - resetMargin {
                yellowAlerted = false
                redAlerted = false
            }
        }
    }

    private func fireAlert(title: String, body: String) {
        // System notification banner (requires the user to have granted
        // TempMonitor permission in System Settings > Notifications).
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .defaultCritical
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)

        // Audible fallback that doesn't depend on notification permission.
        NSSound(named: "Sosumi")?.play()
    }

    private static func readTemperature(toolPath: String) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = ["-c"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let digitsAndDot = output.filter { $0.isNumber || $0 == "." }
        return Double(digitsAndDot)
    }
}

// MARK: - Menu bar widget

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private weak var mainWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: 34)
        item.button?.imagePosition = .imageOnly
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        statusItem = item
        updateIcon(current: 0, average: 0)

        TemperatureReader.shared.onSample = { [weak self] value, history in
            // Drive the icon off the rolling 5-minute average rather than
            // the raw per-second value: the raw reading jitters constantly
            // and would make the menu bar icon distractingly noisy.
            let average = history.isEmpty ? value : history.reduce(0, +) / Double(history.count)
            self?.updateIcon(current: value, average: average)
        }
        TemperatureReader.shared.start()
    }

    // Called from ContentView once the SwiftUI window exists, so the
    // status item can bring it back and so closing it just hides it
    // instead of tearing it (and the menu bar readings) down.
    func attach(window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func statusItemClicked() {
        NSApp.activate(ignoringOtherApps: true)
        (mainWindow ?? NSApp.windows.first)?.makeKeyAndOrderFront(nil)
    }

    // Renders a small thermometer glyph (tube + bulb, mercury filled to
    // the current level) plus the 5-minute average as text, all as one
    // hand-drawn image — matching the app's existing lockFocus-based icon
    // rendering rather than relying on SF Symbol availability/versioning.
    private func updateIcon(current: Double, average: Double) {
        let mercuryColor: NSColor
        if average >= ThermalSpec.red {
            mercuryColor = .systemRed
        } else if average >= ThermalSpec.yellow {
            mercuryColor = .systemYellow
        } else {
            mercuryColor = .systemGreen
        }

        // Non-template image (so severity color survives), so pick an ink
        // color by hand that matches the menu bar's current light/dark
        // appearance instead of relying on the OS to invert it for us.
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let inkColor: NSColor = isDark ? .white : .black

        let displayText = average > 0 ? String(format: "%.0f°", average) : "--"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inkColor]
        let textSize = displayText.size(withAttributes: attributes)

        let iconHeight: CGFloat = 18
        let bulbDiameter: CGFloat = 8
        let tubeWidth: CGFloat = 3.4
        let bulbCenterX = bulbDiameter / 2 + 1
        let tubeBottom = bulbDiameter / 2 // tube visually merges into the bulb
        let tubeTop = iconHeight - 1
        let tubeHeight = tubeTop - tubeBottom
        let tubeRect = NSRect(x: bulbCenterX - tubeWidth / 2, y: tubeBottom, width: tubeWidth, height: tubeHeight)
        let bulbRect = NSRect(x: bulbCenterX - bulbDiameter / 2, y: 0, width: bulbDiameter, height: bulbDiameter)

        let size = NSSize(width: bulbDiameter + 6 + textSize.width, height: iconHeight)
        let image = NSImage(size: size)
        image.lockFocus()

        let tubePath = NSBezierPath(roundedRect: tubeRect, xRadius: tubeWidth / 2, yRadius: tubeWidth / 2)
        inkColor.withAlphaComponent(0.6).setStroke()
        tubePath.lineWidth = 1
        tubePath.stroke()

        let fraction = min(max((average - ThermalSpec.chartFloor) / (ThermalSpec.chartCeiling - ThermalSpec.chartFloor), 0), 1)
        let fillHeight = tubeHeight * CGFloat(fraction)
        if fillHeight > 0 {
            NSGraphicsContext.saveGraphicsState()
            tubePath.addClip()
            mercuryColor.setFill()
            NSBezierPath(rect: NSRect(x: tubeRect.minX, y: tubeRect.minY, width: tubeRect.width, height: fillHeight)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let bulbPath = NSBezierPath(ovalIn: bulbRect)
        mercuryColor.setFill()
        bulbPath.fill()
        inkColor.withAlphaComponent(0.6).setStroke()
        bulbPath.lineWidth = 1
        bulbPath.stroke()

        displayText.draw(at: NSPoint(x: bulbDiameter + 6, y: (iconHeight - textSize.height) / 2), withAttributes: attributes)

        image.unlockFocus()
        image.isTemplate = false
        statusItem.button?.image = image
        // Hover still shows the live instantaneous reading, distinct from
        // the smoothed average the icon itself displays.
        statusItem.button?.toolTip = current > 0 ? String(format: "%.1f°C", current) : nil
    }
}

// MARK: - Chart

struct TemperatureChart: View {
    let values: [Double]
    var emptyMessage: String? = nil

    private func y(for value: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(value, ThermalSpec.chartFloor), ThermalSpec.chartCeiling)
        let fraction = (clamped - ThermalSpec.chartFloor) / (ThermalSpec.chartCeiling - ThermalSpec.chartFloor)
        return height - (CGFloat(fraction) * height)
    }

    private func lineColor(for value: Double) -> Color {
        if value >= ThermalSpec.red { return .red }
        if value >= ThermalSpec.yellow { return .yellow }
        return .green
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                // Grid lines every 10 degrees
                Path { path in
                    var t = ThermalSpec.chartFloor
                    while t <= ThermalSpec.chartCeiling {
                        let py = y(for: t, height: height)
                        path.move(to: CGPoint(x: 0, y: py))
                        path.addLine(to: CGPoint(x: width, y: py))
                        t += 10
                    }
                }
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)

                // Vertical gridlines at the same time fractions as the x-axis labels below
                Path { path in
                    for fraction in [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0] {
                        let px = CGFloat(fraction) * width
                        path.move(to: CGPoint(x: px, y: 0))
                        path.addLine(to: CGPoint(x: px, y: height))
                    }
                }
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)

                // Yellow threshold (85%)
                thresholdLine(value: ThermalSpec.yellow, color: .yellow, width: width, height: height)
                // Red threshold (95%)
                thresholdLine(value: ThermalSpec.red, color: .red, width: width, height: height)

                // Temperature line, colored by current severity
                if values.count > 1 {
                    Path { path in
                        let stepX = width / CGFloat(max(values.count - 1, 1))
                        for (index, value) in values.enumerated() {
                            let point = CGPoint(x: CGFloat(index) * stepX, y: y(for: value, height: height))
                            if index == 0 {
                                path.move(to: point)
                            } else {
                                path.addLine(to: point)
                            }
                        }
                    }
                    .stroke(lineColor(for: values.last ?? 0), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                } else if let message = emptyMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func thresholdLine(value: Double, color: Color, width: CGFloat, height: CGFloat) -> some View {
        let py = y(for: value, height: height)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: py))
                path.addLine(to: CGPoint(x: width, y: py))
            }
            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

            Text("\(Int(value))°")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .padding(.leading, 4)
                .offset(y: py - 12)
        }
    }
}

// X-axis: elapsed time behind "now", derived from the total seconds a
// pane's data spans (sample count * seconds-per-sample) rather than
// wall-clock timestamps.
struct TimeAxisLabels: View {
    let totalSeconds: Double

    private func label(atFraction fraction: Double) -> String {
        guard totalSeconds > 1 else { return "" }
        let ageSeconds = Int((totalSeconds * (1 - fraction)).rounded())
        if ageSeconds <= 0 { return "now" }
        if ageSeconds < 60 { return "-\(ageSeconds)s" }
        if ageSeconds < 3600 { return "-\(ageSeconds / 60)m" }
        return String(format: "-%.1fh", Double(ageSeconds) / 3600.0)
    }

    var body: some View {
        HStack {
            Text(label(atFraction: 0)).frame(maxWidth: .infinity, alignment: .leading)
            Text(label(atFraction: 1.0 / 3.0)).frame(maxWidth: .infinity, alignment: .center)
            Text(label(atFraction: 2.0 / 3.0)).frame(maxWidth: .infinity, alignment: .center)
            Text(label(atFraction: 1)).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 9))
        .foregroundColor(.secondary)
    }
}

// MARK: - Main view

struct ContentView: View {
    @ObservedObject private var reader = TemperatureReader.shared

    private var statusColor: Color {
        if reader.current >= ThermalSpec.red { return .red }
        if reader.current >= ThermalSpec.yellow { return .yellow }
        return .green
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU Temperature")
                        .font(.headline)
                    Text("i7-10700K · Tj max 100°C")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(reader.current > 0 ? String(format: "%.1f°C", reader.current) : "—")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(statusColor)
                    Text(reader.maxSeen > 0 ? String(format: "max %.1f°C", reader.maxSeen) : " ")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding([.top, .horizontal])

            paneLabel("Live — last 5 min")
            TemperatureChart(values: reader.rawHistory)
                .frame(height: 110)
                .padding(.horizontal)
            TimeAxisLabels(totalSeconds: Double(reader.rawHistory.count))
                .padding(.horizontal)

            paneLabel("History — last 3h, 5-min avg")
            TemperatureChart(values: reader.bucketHistory, emptyMessage: "Collecting data — first 5-min average lands soon")
                .frame(height: 110)
                .padding(.horizontal)
            TimeAxisLabels(totalSeconds: Double(reader.bucketHistory.count) * HistorySpec.bucketSeconds)
                .padding(.horizontal)
                .padding(.bottom)

            if reader.alertLevel != .none {
                alertBanner
                    .padding(.horizontal)
            }

            HStack(spacing: 16) {
                legendDot(color: .green, label: "Normal")
                legendDot(color: .yellow, label: "85°C warn")
                legendDot(color: .red, label: "95°C hot")
                Spacer()
            }
            .padding([.horizontal, .bottom])
            .font(.caption2)
        }
        .frame(minWidth: 320, idealWidth: 420, minHeight: 480, idealHeight: 600)
        .background(WindowAccessor { window in
            AppDelegate.shared.attach(window: window)
        })
    }

    private var alertBanner: some View {
        let critical = reader.alertLevel == .critical
        return HStack(spacing: 6) {
            Image(systemName: critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
            Text(critical ? "Critical: at or above 95°C" : "Warning: at or above 85°C")
                .font(.caption.bold())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .foregroundColor(.white)
        .background((critical ? Color.red : Color.yellow.opacity(0.9)))
        .cornerRadius(6)
    }

    private func paneLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundColor(.secondary)
        }
    }
}

// Bridges to AppKit just to capture the NSWindow hosting this SwiftUI
// view, so the menu bar item can bring it forward and hide-not-close it.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - App entry point

struct TempMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("iMac Temperature") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

TempMonitorApp.main()
