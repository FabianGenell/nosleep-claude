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
            (3.2, 12), (7.4, 12), (8.9, 15.5), (11.5, 8.3), (13.2, 12.5), (14.4, 11.7), (20.9, 11.7),
        ]
        let trace = NSBezierPath()
        trace.move(to: NSPoint(x: points[0].0 * k, y: points[0].1 * k))
        for point in points.dropFirst() {
            trace.line(to: NSPoint(x: point.0 * k, y: point.1 * k))
        }
        trace.lineWidth = 2.1 * k
        trace.lineCapStyle = .butt
        trace.lineJoinStyle = .miter
        trace.miterLimit = 3

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

struct SessionInfo {
    var id = ""
    var project = ""
    var label = ""
    var secondsLeft = 0

    var title: String { project.isEmpty ? "session \(id)" : project }

    // Older hook versions stored the prompt verbatim, so strip the markup that
    // rides along with pasted images and task notifications.
    var readableLabel: String {
        var text = label
        for pattern in ["<[^>]*>", "\\[Image #[0-9]+\\]", "\\[Request interrupted[^\\]]*\\]",
                        "toolu_[A-Za-z0-9]*", "[A-Za-z0-9_-]{16,}"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }
}

struct Stats {
    var todayHeld = 0
    var todayWorked = 0
    var todayPrompts = 0
    var weekHeld = 0
    var allHeld = 0
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
    var sessionList: [SessionInfo] = []
    var stats = Stats()

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


// MARK: - menu styling
//
// A menu of disabled NSMenuItems renders as one flat grey column with no
// hierarchy, so the readout is built from custom views instead: only the
// things you can actually click stay ordinary menu items.

enum Style {
    static let width: CGFloat = 308
    static let inset: CGFloat = 15
}

func label(_ text: String,
           size: CGFloat,
           weight: NSFont.Weight = .regular,
           color: NSColor = .labelColor,
           tracking: CGFloat = 0,
           monoDigits: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = monoDigits
        ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.cell?.truncatesLastVisibleLine = true
    if tracking != 0 {
        field.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: field.font as Any,
                         .foregroundColor: color,
                         .kern: tracking])
    }
    return field
}

func stack(_ views: [NSView],
           axis: NSUserInterfaceLayoutOrientation,
           spacing: CGFloat,
           alignment: NSLayoutConstraint.Attribute) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = axis
    view.spacing = spacing
    view.alignment = alignment
    return view
}

func menuRow(_ content: NSView, top: CGFloat = 5, bottom: CGFloat = 5) -> NSMenuItem {
    let box = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(content)
    NSLayoutConstraint.activate([
        box.widthAnchor.constraint(equalToConstant: Style.width),
        content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Style.inset),
        content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Style.inset),
        content.topAnchor.constraint(equalTo: box.topAnchor, constant: top),
        content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -bottom),
    ])
    box.layoutSubtreeIfNeeded()
    box.frame = NSRect(x: 0, y: 0, width: Style.width,
                       height: content.fittingSize.height + top + bottom)
    let item = NSMenuItem()
    item.view = box
    return item
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
        next.sessionList = (json["sessions_detail"] as? [[String: Any]] ?? []).map { row in
            SessionInfo(
                id: row["session"] as? String ?? "",
                project: row["project"] as? String ?? "",
                label: row["label"] as? String ?? "",
                secondsLeft: row["seconds_left"] as? Int ?? 0)
        }
        if let raw = json["stats"] as? [String: Any] {
            next.stats = Stats(
                todayHeld: raw["today_held"] as? Int ?? 0,
                todayWorked: raw["today_worked"] as? Int ?? 0,
                todayPrompts: raw["today_prompts"] as? Int ?? 0,
                weekHeld: raw["week_held"] as? Int ?? 0,
                allHeld: raw["all_held"] as? Int ?? 0)
        }
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

        // Glyph only. A countdown in the bar costs width every minute of the
        // day to answer a question that is one click away.
        if let image {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = snapshot.sleepBlocked ? "awake" : "zzz"
        }

        if manualHold != nil { description += " (manual hold)" }
        if snapshot.blockedByClaude && snapshot.secondsLeft > 0 {
            description += ", \(humanShort(snapshot.secondsLeft)) left"
        }
        button.toolTip = description
    }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        menu.minimumWidth = Style.width

        menu.addItem(headerRow())

        if snapshot.cliMissing {
            menu.addItem(menuRow(label("Looked for \(cliPath)", size: 11, color: .secondaryLabelColor)))
            menu.addItem(.separator())
            addAction("Quit", #selector(quit))
            return
        }

        if !snapshot.sessionList.isEmpty {
            menu.addItem(.separator())
            let sorted = snapshot.sessionList.sorted { $0.secondsLeft > $1.secondsLeft }
            for session in sorted.prefix(4) {
                menu.addItem(sessionRow(session))
            }
            if sorted.count > 4 {
                menu.addItem(menuRow(label("+\(sorted.count - 4) more", size: 11,
                                           color: .tertiaryLabelColor), top: 0, bottom: 4))
            }
        }

        menu.addItem(.separator())
        menu.addItem(menuRow(todayRow(), top: 4, bottom: 5))

        menu.addItem(.separator())
        let hold = addAction(manualHold == nil ? "Keep awake for 1 hour" : "Release manual hold",
                             #selector(toggleManualHold))
        hold.state = manualHold == nil ? .off : .on

        // The rarely-wanted bits live one level down so the menu stays short.
        let details = NSMenu()
        for (title, selector) in [("Copy status", #selector(copyStatus)),
                                  ("Copy stats", #selector(copyStats)),
                                  ("Open log", #selector(openLog))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            details.addItem(item)
        }
        let detailsItem = NSMenuItem(title: "Details", action: nil, keyEquivalent: "")
        detailsItem.submenu = details
        menu.addItem(detailsItem)

        addAction("Quit", #selector(quit))
    }

    // MARK: - rows

    func headerRow() -> NSMenuItem {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = statusColor.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        let title = label(snapshot.headline, size: 14, weight: .semibold)

        // The holder list is only worth the line when Claude is not the one
        // holding it: the sessions below already account for that case.
        var detail: String?
        if snapshot.cliMissing {
            detail = "nosleep-claude CLI not found"
        } else if !snapshot.healthy {
            detail = "run nosleep-claude status"
        } else if snapshot.sleepBlocked && !snapshot.blockedByClaude {
            let other = snapshot.blockedBy.filter { $0 != "nosleep-claude" }
            detail = other.isEmpty ? nil : "held by \(other[0])"
                + (other.count > 1 ? " +\(other.count - 1)" : "")
        }

        var column: [NSView] = [title]
        if let detail {
            column.append(label(detail, size: 11, color: .secondaryLabelColor))
        }
        let text = stack(column, axis: .vertical, spacing: 1, alignment: .leading)
        let dotColumn = stack([dot, NSView()], axis: .vertical, spacing: 0, alignment: .centerX)
        dotColumn.setHuggingPriority(.defaultHigh, for: .horizontal)

        let row = stack([dot, text], axis: .horizontal, spacing: 9, alignment: .firstBaseline)
        row.alignment = .top
        return menuRow(row, top: 10, bottom: 4)
    }

    var statusColor: NSColor {
        if snapshot.cliMissing || !snapshot.healthy { return .systemOrange }
        if snapshot.blockedByClaude { return .systemGreen }
        if snapshot.sleepBlocked { return .systemTeal }
        return .tertiaryLabelColor
    }

    func sessionRow(_ session: SessionInfo) -> NSMenuItem {
        let name = label(session.title, size: 12.5, weight: .medium)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let remaining = label(humanShort(session.secondsLeft), size: 11,
                              weight: .regular, color: .tertiaryLabelColor, monoDigits: true)
        remaining.setContentHuggingPriority(.required, for: .horizontal)
        remaining.setContentCompressionResistancePriority(.required, for: .horizontal)

        let top = stack([name, NSView(), remaining], axis: .horizontal, spacing: 8, alignment: .firstBaseline)
        let readable = session.readableLabel
        let prompt = label(readable.isEmpty ? "waiting for its next prompt" : readable,
                           size: 11, color: .secondaryLabelColor)
        let column = stack([top, prompt], axis: .vertical, spacing: 1, alignment: .leading)
        column.setHuggingPriority(.defaultLow, for: .horizontal)
        return menuRow(column, top: 4, bottom: 4)
    }

    func todayRow() -> NSView {
        let stats = snapshot.stats
        let line = "Today  \(humanShort(stats.todayHeld)) awake · \(humanShort(stats.todayWorked)) working"
        return label(line, size: 11.5, color: .secondaryLabelColor, monoDigits: true)
    }

    @discardableResult
    func addAction(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
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

    @objc func copyStats() {
        guard let out = run(cliPath, ["stats"]) else { return }
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


// Rendering the menu offscreen is the only way to check its layout without
// opening it by hand, which a menu bar manager can make impossible.
extension Controller {
    func previewImage(dark: Bool) -> NSImage {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        menuNeedsUpdate(menu)

        var rows: [(NSImage?, NSMenuItem)] = []
        var height: CGFloat = 12
        for item in menu.items {
            if let view = item.view {
                view.appearance = appearance
                view.layoutSubtreeIfNeeded()
                let bounds = view.bounds
                var image: NSImage?
                if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
                    view.cacheDisplay(in: bounds, to: rep)
                    let shot = NSImage(size: bounds.size)
                    shot.addRepresentation(rep)
                    image = shot
                }
                rows.append((image, item))
                height += bounds.height
            } else if item.isSeparatorItem {
                rows.append((nil, item))
                height += 11
            } else {
                rows.append((nil, item))
                height += 22
            }
        }
        height += 12

        let canvas = NSImage(size: NSSize(width: Style.width, height: height))
        canvas.lockFocus()
        NSAppearance.current = appearance
        (dark ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: Style.width, height: height).fill()

        var y = height - 12
        for (image, item) in rows {
            if let image {
                y -= image.size.height
                image.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .sourceOver, fraction: 1)
            } else if item.isSeparatorItem {
                y -= 11
                (dark ? NSColor(calibratedWhite: 1, alpha: 0.14) : NSColor(calibratedWhite: 0, alpha: 0.12)).setFill()
                NSRect(x: Style.inset, y: y + 5, width: Style.width - Style.inset * 2, height: 1).fill()
            } else {
                y -= 22
                let text = NSAttributedString(string: item.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: dark ? NSColor.white : NSColor.black,
                ])
                text.draw(at: NSPoint(x: Style.inset, y: y + 4))
            }
        }
        canvas.unlockFocus()
        return canvas
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

// `nosleepbar --preview-menu <path>` draws the menu to a PNG and exits.
if let flag = args.firstIndex(of: "--preview-menu"), args.count > flag + 1 {
    let base = args[flag + 1]
    for (suffix, dark) in [("-dark", true), ("-light", false)] {
        let image = controller.previewImage(dark: dark)
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let path = base.replacingOccurrences(of: ".png", with: "\(suffix).png")
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
    exit(0)
}

app.run()
