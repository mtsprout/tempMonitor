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

    @Published var history: [Double] = []
    @Published var current: Double = 0
    @Published var maxSeen: Double = 0
    @Published var alertLevel: AlertLevel = .none

    // Notified on every sample so the menu bar icon can redraw itself.
    var onSample: ((Double, [Double]) -> Void)?

    private var timer: Timer?
    private let capacity = 180 // 3 minutes at 1s resolution
    private let toolPath = "/usr/local/bin/osx-cpu-temp"

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
            self.history.append(value)
            if self.history.count > self.capacity {
                self.history.removeFirst(self.history.count - self.capacity)
            }
            self.checkThresholds(value)
            self.onSample?(value, self.history)
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
        updateIcon(value: 0, history: [])

        TemperatureReader.shared.onSample = { [weak self] value, history in
            self?.updateIcon(value: value, history: history)
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

    private func updateIcon(value: Double, history: [Double]) {
        let color: NSColor
        if value >= ThermalSpec.red {
            color = .systemRed
        } else if value >= ThermalSpec.yellow {
            color = .systemYellow
        } else {
            color = .systemGreen
        }

        let size = NSSize(width: 28, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let recent = Array(history.suffix(28))
        if recent.count > 1 {
            let minV = ThermalSpec.chartFloor
            let maxV = ThermalSpec.chartCeiling
            let stepX = size.width / CGFloat(max(recent.count - 1, 1))
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            for (index, sample) in recent.enumerated() {
                let clamped = min(max(sample, minV), maxV)
                let fraction = (clamped - minV) / (maxV - minV)
                let point = NSPoint(x: CGFloat(index) * stepX, y: 1 + CGFloat(fraction) * (size.height - 2))
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.line(to: point)
                }
            }
            color.setStroke()
            path.stroke()
        }

        image.unlockFocus()
        image.isTemplate = false
        statusItem.button?.image = image
        statusItem.button?.toolTip = value > 0 ? String(format: "%.1f°C", value) : nil
    }
}

// MARK: - Chart

struct TemperatureChart: View {
    let history: [Double]

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

                // Yellow threshold (85%)
                thresholdLine(value: ThermalSpec.yellow, color: .yellow, width: width, height: height)
                // Red threshold (95%)
                thresholdLine(value: ThermalSpec.red, color: .red, width: width, height: height)

                // Temperature line, colored by current severity
                if history.count > 1 {
                    Path { path in
                        let stepX = width / CGFloat(max(history.count - 1, 1))
                        for (index, value) in history.enumerated() {
                            let point = CGPoint(x: CGFloat(index) * stepX, y: y(for: value, height: height))
                            if index == 0 {
                                path.move(to: point)
                            } else {
                                path.addLine(to: point)
                            }
                        }
                    }
                    .stroke(lineColor(for: history.last ?? 0), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
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

            TemperatureChart(history: reader.history)
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
        .frame(minWidth: 320, idealWidth: 400, minHeight: 320, idealHeight: 400)
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
