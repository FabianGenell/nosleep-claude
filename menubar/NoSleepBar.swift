// NoSleepBar: a menu bar readout of whether this Mac is going to sleep.
//
// It renders `nosleep-claude status --json`, so the CLI stays the single
// source of truth and this file stays a view. Polls every few seconds and
// again whenever the menu opens.

import Cocoa

let pollInterval: TimeInterval = 5
let manualHoldSeconds = 3600

// Awake is a filled disc with the pulse trace knocked out of it, drawn below
// because SF Symbols has no equivalent. Asleep is the stock hollow ring.
// Setting NOSLEEP_SYMBOL_AWAKE swaps the disc for that symbol instead, so a
// different pair can be tried from the LaunchAgent without rebuilding.
let awakeSymbol = ProcessInfo.processInfo.environment["NOSLEEP_SYMBOL_AWAKE"]
let sleepSymbol = ProcessInfo.processInfo.environment["NOSLEEP_SYMBOL_SLEEP"]
    ?? "minus.circle"

// Menu bar glyphs sit in a 22pt content area. 20 puts the disc at the same
// visual weight as neighbouring items; NOSLEEP_GLYPH_SIZE tunes it.
let glyphSize: CGFloat = {
    guard let raw = ProcessInfo.processInfo.environment["NOSLEEP_GLYPH_SIZE"],
          let requested = Double(raw) else { return 20 }
    return min(max(CGFloat(requested), 12), 22)
}()

// Drawn in a 24x24 space to match how the candidates were designed, then
// scaled down: a disc, with the trace removed from it rather than laid on top,
// so the glyph stays a single solid mark in the bar.
func pulseDiscImage(size: CGFloat = glyphSize) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current else { return false }
        let k = size / 24

        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1 * k, y: 1 * k, width: 22 * k, height: 22 * k)).fill()

        // y runs upward here, so the trace is mirrored from the SVG sketch.
        // Kept well inside the rim: a trace that reaches the edge cuts notches
        // in the disc and the mark stops reading as solid.
        let points: [(CGFloat, CGFloat)] = [
            (5.5, 12), (7.8, 12), (9.1, 16.4), (11.5, 7.3), (13.2, 12.7), (14.3, 11.6), (18.5, 11.6),
        ]
        let trace = NSBezierPath()
        trace.move(to: NSPoint(x: points[0].0 * k, y: points[0].1 * k))
        for point in points.dropFirst() {
            trace.line(to: NSPoint(x: point.0 * k, y: point.1 * k))
        }
        trace.lineWidth = 2.1 * k
        trace.lineCapStyle = .butt
        trace.lineJoinStyle = .miter
        trace.miterLimit = 6

        ctx.compositingOperation = .destinationOut
        NSColor.black.setStroke()
        trace.stroke()
        return true
    }
    image.isTemplate = true
    return image
}

func symbolImage(_ name: String, _ description: String) -> NSImage? {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description) else { return nil }
    image.isTemplate = true
    return image
}

struct Snapshot {
    var verdict = "UNKNOWN"
    var healthy = false
    var sleepBlocked = false
    var blockedBy: [String] = []
    var sessions = 0
    var secondsLeft = 0
    var lidRuleInstalled = false
    var lidClosedBlocked = false
    var lastHookAge = -1
    var cliMissing = false

    var blockedByClaude: Bool { blockedBy.contains("nosleep-claude") }

    var headline: String {
        if cliMissing { return "nosleep-claude CLI not found" }
        if !healthy { return "nosleep-claude is not running" }
        if sessions > 0 && secondsLeft > 0 { return "Staying awake for \(humanShort(secondsLeft))" }
        if sleepBlocked { return "Staying awake" }
        return "Will sleep when idle"
    }
}

func humanShort(_ secs: Int) -> String {
    if secs < 60 { return "\(secs)s" }
    if secs < 3600 { return "\(secs / 60)m" }
    return "\(secs / 3600)h \((secs % 3600) / 60)m"
}

func humanAge(_ secs: Int) -> String {
    if secs < 0 { return "never" }
    if secs < 60 { return "\(secs)s ago" }
    if secs < 3600 { return "\(secs / 60)m ago" }
    if secs < 86400 { return "\(secs / 3600)h ago" }
    return "\(secs / 86400)d ago"
}

@discardableResult
func run(_ launchPath: String, _ args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

final class Controller: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var snapshot = Snapshot()
    var timer: Timer?
    var manualHold: Process?
    let cliPath: String

    override init() {
        // Prefer an explicit path, then PATH-ish locations, then the repo.
        let candidates = [
            ProcessInfo.processInfo.environment["NOSLEEP_CLI"],
            "\(NSHomeDirectory())/.local/bin/nosleep-claude",
            "/usr/local/bin/nosleep-claude",
            "/opt/homebrew/bin/nosleep-claude",
        ].compactMap { $0 }
        cliPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
        super.init()

        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - data

    func refresh() {
        var next = Snapshot()
        guard FileManager.default.isExecutableFile(atPath: cliPath),
              let out = run(cliPath, ["status", "--json"]),
              let data = out.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            next.cliMissing = true
            snapshot = next
            render()
            return
        }
        next.verdict = json["verdict"] as? String ?? "UNKNOWN"
        next.healthy = json["healthy"] as? Bool ?? false
        next.sleepBlocked = json["sleep_blocked"] as? Bool ?? false
        next.blockedBy = json["blocked_by"] as? [String] ?? []
        next.sessions = json["sessions"] as? Int ?? 0
        next.secondsLeft = json["seconds_left"] as? Int ?? 0
        next.lidRuleInstalled = json["lid_rule_installed"] as? Bool ?? false
        next.lidClosedBlocked = json["lid_closed_blocked"] as? Bool ?? false
        next.lastHookAge = json["last_hook_age"] as? Int ?? -1
        snapshot = next
        render()
    }

    // MARK: - menu bar item

    func render() {
        guard let button = statusItem.button else { return }
        var description = snapshot.headline
        let image: NSImage?

        if snapshot.cliMissing || !snapshot.healthy {
            image = symbolImage("exclamationmark.triangle", description)
        } else if snapshot.sleepBlocked {
            image = awakeSymbol.flatMap { symbolImage($0, description) } ?? pulseDiscImage()
        } else {
            image = symbolImage(sleepSymbol, description)
        }

        if let image {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = snapshot.sleepBlocked ? "awake" : "zzz"
        }

        // Only Claude's own hold gets a countdown; other holders come and go
        // on their own schedule and a number there would be made up.
        if snapshot.blockedByClaude && snapshot.secondsLeft > 0 {
            button.title = " \(humanShort(snapshot.secondsLeft))"
        } else if manualHold != nil {
            button.title = " hold"
        } else if !snapshot.cliMissing && snapshot.healthy {
            button.title = ""
        }

        if manualHold != nil { description += " (manual hold)" }
        button.toolTip = description
    }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        addHeader(snapshot.headline)

        if snapshot.cliMissing {
            addInfo("Looked for: \(cliPath)")
            addSeparator()
            addAction("Quit", #selector(quit))
            return
        }

        if !snapshot.healthy {
            addInfo("Hooks have not fired. Run nosleep-claude status")
        } else if snapshot.sleepBlocked {
            addInfo("Held by: \(snapshot.blockedBy.joined(separator: ", "))")
        } else {
            addInfo("Nothing is holding sleep open")
        }

        addSeparator()
        addInfo(snapshot.sessions > 0
            ? "Claude sessions holding it: \(snapshot.sessions)"
            : "No Claude session holding it")
        addInfo("Last Claude hook: \(humanAge(snapshot.lastHookAge))")
        addInfo(snapshot.lidRuleInstalled
            ? "Lid closed on battery: \(snapshot.lidClosedBlocked ? "stays awake" : "sleeps (no active prompt)")"
            : "Lid closed on battery: sleeps (rule not installed)")

        addSeparator()
        let hold = addAction(manualHold == nil ? "Keep awake for 1 hour" : "Release manual hold",
                             #selector(toggleManualHold))
        hold.state = manualHold == nil ? .off : .on
        addAction("Copy status", #selector(copyStatus))
        addAction("Open log", #selector(openLog))
        addSeparator()
        addAction("Quit", #selector(quit))
    }

    @discardableResult
    func addAction(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    func addHeader(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
        item.isEnabled = false
        menu.addItem(item)
    }

    func addInfo(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        item.isEnabled = false
        menu.addItem(item)
    }

    func addSeparator() { menu.addItem(.separator()) }

    // MARK: - actions

    @objc func toggleManualHold() {
        if let held = manualHold {
            held.terminate()
            manualHold = nil
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-imsu", "-t", "\(manualHoldSeconds)"]
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.manualHold = nil
                    self?.render()
                }
            }
            try? process.run()
            manualHold = process
        }
        refresh()
    }

    @objc func copyStatus() {
        guard let out = run(cliPath, ["status"]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
    }

    @objc func openLog() {
        let log = "/tmp/nosleep-claude/nosleep-claude.log"
        if FileManager.default.fileExists(atPath: log) {
            NSWorkspace.shared.open(URL(fileURLWithPath: log))
        }
    }

    @objc func quit() {
        manualHold?.terminate()
        NSApp.terminate(nil)
    }
}

// `nosleepbar --export-icon <path>` writes the awake glyph to a PNG, which is
// the only way to look at a hand-drawn template image without the bar.
let args = CommandLine.arguments
if let flag = args.firstIndex(of: "--export-icon"), args.count > flag + 1 {
    let scale: CGFloat = 8
    let image = pulseDiscImage(size: glyphSize * scale)
    if let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: args[flag + 1]))
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.run()
