// NoSleepBar: a menu bar readout of whether this Mac is going to sleep.
//
// It renders `nosleep-claude status --json`, so the CLI stays the single
// source of truth and this file stays a view. Polls every few seconds and
// again whenever the menu opens.

import Cocoa

let pollInterval: TimeInterval = 5
let manualHoldSeconds = 3600

// The two glyphs. Override either with an env var in the LaunchAgent to try
// a different pair without rebuilding.
let awakeSymbol = ProcessInfo.processInfo.environment["NOSLEEP_SYMBOL_AWAKE"]
    ?? "waveform.path.ecg"
let sleepSymbol = ProcessInfo.processInfo.environment["NOSLEEP_SYMBOL_SLEEP"]
    ?? "minus"

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
        let symbol: String
        var description = snapshot.headline

        if snapshot.cliMissing || !snapshot.healthy {
            symbol = "exclamationmark.triangle"
        } else if snapshot.sleepBlocked {
            symbol = awakeSymbol
        } else {
            symbol = sleepSymbol
        }

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) {
            image.isTemplate = true
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.run()
