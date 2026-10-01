import AppKit
import ServiceManagement

let defaults = UserDefaults.standard
defaults.register(defaults: ["showLeft": true, "showWeekly": false, "interval": 300.0])

func color(_ limit: Limit) -> NSColor {
    let severity = limit.severity.lowercased()
    if limit.used >= 95 || ["critical", "exceeded", "blocked", "limited"].contains(severity) { return .systemRed }
    if limit.used >= 80 || ["warning", "high"].contains(severity) { return .systemOrange }
    return limit.used >= 60 ? .systemYellow : .systemGreen
}

func alert(_ limit: Limit) -> NSColor? {
    let tint = color(limit)
    return tint == .systemRed || tint == .systemOrange ? tint : nil
}

func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

func until(_ date: Date) -> String {
    let minutes = max(0, Int(date.timeIntervalSinceNow) + 59) / 60
    let (d, h, m) = (minutes / 1440, minutes % 1440 / 60, minutes % 60)
    if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    return "\(m)m"
}

func clock(_ date: Date) -> String {
    let date = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    let formatter = DateFormatter()
    let template = Calendar.current.isDateInToday(date) ? "jmm" : date.timeIntervalSinceNow < 6 * 86400 ? "EEE jmm" : "MMM d jmm"
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
}

func ring(_ fraction: Double) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        let box = rect.insetBy(dx: 2.2, dy: 2.2)
        let center = NSPoint(x: box.midX, y: box.midY)
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: box.width / 2, startAngle: 0, endAngle: 360)
        track.lineWidth = 2.4
        NSColor.black.withAlphaComponent(0.25).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: box.width / 2, startAngle: 90,
                      endAngle: 90 - 360 * min(max(fraction, 0), 0.9999), clockwise: true)
        arc.lineWidth = 2.4
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        if fraction > 0.001 { arc.stroke() }
        return true
    }
    image.isTemplate = true
    return image
}

final class Bar: NSView {
    var fraction = 0.0
    var color = NSColor.systemGreen

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        guard fraction > 0 else { return }
        color.setFill()
        let fill = NSRect(x: 0, y: 0, width: max(fraction * bounds.width, bounds.height), height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
    }
}

func row(_ limit: Limit, showLeft: Bool) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 54))
    let title = NSTextField(labelWithString: limit.title)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    let value = NSTextField(labelWithString: "\(percent(limit.shown(showLeft))) \(showLeft ? "left" : "used")")
    value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    value.textColor = alert(limit) ?? .labelColor
    let reset = limit.resetsAt.map { $0 > Date() ? "Resets in \(until($0)) · \(clock($0))" : "Window has reset" }
    let subtitle = NSTextField(labelWithString: reset ?? "No reset time reported")
    subtitle.font = .systemFont(ofSize: 11)
    subtitle.textColor = .secondaryLabelColor
    let bar = Bar()
    bar.fraction = limit.shown(showLeft) / 100
    bar.color = color(limit)

    for sub in [title, value, subtitle, bar] {
        sub.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sub)
    }
    NSLayoutConstraint.activate([
        title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
        title.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
        value.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
        value.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
        bar.trailingAnchor.constraint(equalTo: value.trailingAnchor),
        bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
        bar.heightAnchor.constraint(equalToConstant: 6),
        subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
        subtitle.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
    ])
    return view
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    var usage: Usage?
    var error: UsageError?
    var timer: Timer?
    var fetching = false
    var backoff = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.imagePosition = .imageLeading
        item.button?.font = font
        item.menu = NSMenu()
        item.menu?.delegate = self
        render()
        schedule()
        refresh()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.refresh() }
        }
    }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: defaults.double(forKey: "interval"), repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh(manual: Bool = false) {
        guard !fetching, manual || Date() > backoff else { return }
        fetching = true
        UsageClient.fetch { [self] result in
            fetching = false
            switch result {
            case .success(let usage): (self.usage, error, backoff) = (usage, nil, .distantPast)
            case .failure(let failure):
                error = failure
                if case .rateLimited(let retry) = failure {
                    backoff = Date() + min(max((retry ?? 0) + 15, defaults.double(forKey: "interval"), 180), 900)
                }
            }
            render()
        }
    }

    func render() {
        guard let button = item.button else { return }
        let showLeft = defaults.bool(forKey: "showLeft")
        guard let usage, let session = usage.session else {
            button.image = error == nil ? ring(0) : NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            button.title = error == nil ? "…" : ""
            button.toolTip = error?.errorDescription
            return
        }
        var text = percent(session.shown(showLeft))
        if defaults.bool(forKey: "showWeekly"), let weekly = usage.weekly, weekly.id != session.id {
            text += " · " + percent(weekly.shown(showLeft))
        }
        button.image = ring(session.shown(showLeft) / 100)
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: alert(session) ?? NSColor.controlTextColor])
        button.toolTip = usage.limits.map { "\($0.title): \(percent($0.shown(showLeft))) \(showLeft ? "left" : "used")" }.joined(separator: "\n")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let usage, Date().timeIntervalSince(usage.fetchedAt) > 60 { refresh() }
        let showLeft = defaults.bool(forKey: "showLeft")
        menu.removeAllItems()
        menu.addItem(info(["Claude Code", usage?.plan.map { "\($0.capitalized) plan" }].compactMap { $0 }.joined(separator: " · ")))
        menu.addItem(.separator())
        for limit in usage?.limits ?? [] {
            let entry = NSMenuItem()
            entry.view = row(limit, showLeft: showLeft)
            menu.addItem(entry)
        }
        if let error {
            let text = Date() < backoff ? "Rate limited · retrying at \(clock(backoff))" : error.errorDescription ?? ""
            menu.addItem(info("⚠︎ " + text))
        } else if usage == nil {
            menu.addItem(info("Loading…"))
        }
        menu.addItem(.separator())
        if let usage { menu.addItem(info("Updated at \(clock(usage.fetchedAt))")) }
        menu.addItem(action("Refresh Now", #selector(refreshNow), key: "r"))
        menu.addItem(.separator())
        menu.addItem(action("Show Percentage Left", #selector(toggle(_:)), on: showLeft, tag: "showLeft"))
        menu.addItem(action("Show Weekly in Menu Bar", #selector(toggle(_:)), on: defaults.bool(forKey: "showWeekly"), tag: "showWeekly"))
        let intervals = NSMenu()
        for minutes in [1, 2, 5, 10, 15] {
            let choice = action("\(minutes) min", #selector(pickInterval(_:)), on: Double(minutes * 60) == defaults.double(forKey: "interval"))
            choice.tag = minutes * 60
            intervals.addItem(choice)
        }
        let intervalItem = NSMenuItem(title: "Refresh Every", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervals
        menu.addItem(intervalItem)
        menu.addItem(action("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(action("Open Usage on claude.ai", #selector(openUsage)))
        menu.addItem(action("Quit", #selector(quit), key: "q"))
    }

    func info(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    func action(_ title: String, _ selector: Selector, key: String = "", on: Bool = false, tag: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = self
        entry.state = on ? .on : .off
        entry.representedObject = tag
        return entry
    }

    @objc func refreshNow() { refresh(manual: true) }

    @objc func toggle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        render()
    }

    @objc func pickInterval(_ sender: NSMenuItem) {
        defaults.set(Double(sender.tag), forKey: "interval")
        schedule()
    }

    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        try? service.status == .enabled ? service.unregister() : service.register()
    }

    @objc func openUsage() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }

    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--print") {
    UsageClient.fetch { result in
        switch result {
        case .success(let usage):
            for limit in usage.limits {
                print("\(limit.title): \(percent(limit.used)) used, \(percent(limit.left)) left" + (limit.resetsAt.map { ", resets in \(until($0))" } ?? ""))
            }
            exit(0)
        case .failure(let error):
            print(error.errorDescription ?? "Error")
            exit(1)
        }
    }
    RunLoop.main.run()
}

let app = App()
NSApplication.shared.delegate = app
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
