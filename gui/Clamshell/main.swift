//
//  Clamshell — menu bar companion for the `clamshell` CLI.
//
//  A tiny NSStatusItem that shows whether closing the lid will keep this Mac
//  awake, and lets you switch modes without opening a terminal. All state
//  lives in the CLI; this is only a view onto it.
//
//  SPDX-License-Identifier: MIT
//

import AppKit
import Foundation
import ServiceManagement

// MARK: - Talking to the CLI

/// Mirrors `clamshell json`.
struct Status: Decodable {
    let version: String
    let mode: String
    let displays: Int
    let lidClosed: Bool
    let onBattery: Bool
    let sleepDisabled: Bool
    let watcherRunning: Bool
    let modeFile: String
    let batteryPercent: Int?
    let lowPowerMode: Bool
    let floor: Int?
    let timerMinutes: Int?
    let until: Int?
    let lpmCut: Bool
    let lpmHold: Bool
    let lastCut: String?
}

enum CLI {
    static let path = "/usr/local/bin/clamshell"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    static func status() -> Status? {
        guard isInstalled,
              let output = run(path, ["json"]),
              let data = output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }

    /// Mode, floor, timer and Low Power Mode changes only rewrite files in the
    /// user's home — no sudo.
    static func set(_ args: [String]) {
        guard isInstalled else { return }
        run(path, args)
    }
}

// MARK: - Open at login

/// `SMAppService` on macOS 13+, falling back to a plain LaunchAgent.
///
/// `SMAppService` is the right API — the entry shows up under System Settings →
/// Login Items where people expect to manage it. But it can refuse for a
/// locally built, ad-hoc signed app, and a login toggle that silently does
/// nothing is worse than none at all. So when it throws we write a LaunchAgent
/// instead: launchd scans `~/Library/LaunchAgents` at every login, needs no
/// entitlements, and is one file the user can inspect or delete by hand.
enum LoginItem {
    static let label = "local.clamshell.menubar"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// True once registered, including while macOS is still waiting for the
    /// user to approve it in System Settings.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval: return true
            default: break
            }
        }
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Registered, but macOS wants the user to confirm it first.
    static var needsApproval: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .requiresApproval
        }
        return false
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                removeAgent()          // never leave both mechanisms armed
                return true
            } catch {
                NSLog("clamshell: SMAppService failed (\(error)) — using LaunchAgent")
            }
        }
        return enabled ? writeAgent() : removeAgent()
    }

    @discardableResult
    private static func writeAgent() -> Bool {
        let executable = Bundle.main.executableURL?.path
            ?? "/Applications/Clamshell.app/Contents/MacOS/Clamshell"

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: plistURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private static func removeAgent() -> Bool {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return true }
        // Unload it too, in case launchd already picked it up this session.
        CLI.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        return !FileManager.default.fileExists(atPath: plistURL.path)
    }
}

// MARK: - Icon

/// A laptop, drawn rather than borrowed from SF Symbols so the two states can
/// differ in the one place that carries the meaning: the screen.
///
/// A lit (filled) screen means the machine keeps running with the lid shut; an
/// empty one means closing the lid will put it to sleep.
enum LaptopIcon {
    enum State {
        case awake, asleep, warning
    }

    static func image(for state: State) -> NSImage {
        if state == .warning {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                accessibilityDescription: "clamshell needs attention")
            image?.isTemplate = true
            return image ?? NSImage()
        }

        let size = NSSize(width: 18, height: 14)
        let lit = (state == .awake)

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()

            // Screen: heavy bezel, either lit through or empty.
            let screen = NSBezierPath(
                roundedRect: NSRect(x: 2.7, y: 5.0, width: 12.6, height: 7.6),
                xRadius: 1.1, yRadius: 1.1
            )
            if lit {
                screen.fill()
            } else {
                screen.lineWidth = 1.4
                screen.stroke()
            }

            // Base, foreshortened: the deck tapering out to the front edge.
            let deck = NSBezierPath()
            deck.move(to: NSPoint(x: 2.9, y: 4.9))
            deck.line(to: NSPoint(x: 15.1, y: 4.9))
            deck.line(to: NSPoint(x: 17.0, y: 3.1))
            deck.line(to: NSPoint(x: 1.0, y: 3.1))
            deck.close()
            deck.fill()

            NSBezierPath(
                roundedRect: NSRect(x: 0.6, y: 2.0, width: 16.8, height: 1.6),
                xRadius: 0.8, yRadius: 0.8
            ).fill()

            return true
        }

        image.isTemplate = true
        return image
    }
}

// MARK: - Menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var countdownTimer: Timer?
    private var menuIsOpen = false
    private var status: Status?

    /// While the menu is open the contents must be live; while it is shut the
    /// only consumer is the icon.
    private static let openInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 15

    private static let logPath = "/var/log/clamshell.log"

    /// Status is read by spawning the CLI, so it happens off the main thread.
    /// A menu that blocks on a subprocess while it is opening visibly hitches.
    private let probe = DispatchQueue(label: "local.clamshell.probe", qos: .utility)

    // Built once and then only updated. Rebuilding a live NSMenu makes it
    // resize under the cursor, so the item set has to stay fixed.
    private var headlineItem: NSMenuItem!
    private var contextItem: NSMenuItem!
    private var countdownItem: NSMenuItem!
    private var watcherWarning: NSMenuItem!
    private var drainWarning: NSMenuItem!
    private var lpmWarning: NSMenuItem!
    private var floorParent: NSMenuItem!
    private var timerParent: NSMenuItem!
    private var lpmToggle: NSMenuItem!
    private var approvalWarning: NSMenuItem!
    private var loginToggle: NSMenuItem!
    private var logItem: NSMenuItem!

    // Warning text is applied only while the warning is showing. `isHidden`
    // stops an item drawing but AppKit still measures its title, so a hidden
    // item with a long string silently pads the whole menu's width.
    private let watcherWarningText = "⚠︎ Watcher not running"
    private let drainWarningText = "⚠︎ No display — battery will drain"
    private let lpmWarningText = "⚠︎ Low Power Mode is on — staying awake"
    private let approvalWarningText = "⚠︎ Approve in Login Items"
    private var modeItems: [String: NSMenuItem] = [:]
    private var floorItems: [String: NSMenuItem] = [:]
    private var timerItems: [String: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self

        // One blocking read at launch so the first open is already correct.
        status = CLI.status()
        apply()

        startTicker(interval: Self.idleInterval)
    }

    /// Poll fast only while someone is looking.
    ///
    /// `clamshell json` spawns half a dozen short-lived processes and costs
    /// ~140ms. At the old flat 2s that ran forever, menu open or not — a
    /// steady ~7% of a core spent on a reading nobody was reading, which is a
    /// poor look for an app that exists to save battery. Closed, the only
    /// consumer is the menu bar icon, and 15s is plenty for that.
    ///
    /// Deliberately on `.common` rather than the default run loop mode: while
    /// a menu is open AppKit runs in event-tracking mode, and a plain
    /// scheduled timer is starved for exactly as long as the user is looking
    /// at it — which is the one moment the contents must be live.
    private func startTicker(interval: TimeInterval) {
        timer?.invalidate()
        let ticker = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        countdownTimer?.invalidate()
    }

    /// Called before the menu is laid out. Applies what is already known, then
    /// kicks off a refresh — no structural change, so nothing resizes.
    func menuNeedsUpdate(_ menu: NSMenu) {
        apply()
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        startTicker(interval: Self.openInterval)
        syncCountdownTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        startTicker(interval: Self.idleInterval)
        syncCountdownTimer()
    }

    /// The countdown row only ticks while someone can see it and a deadline is
    /// set. It is a separate 1s timer that just rewrites one title from the
    /// cached `until` — no CLI call, no refresh. On `.common` for the same
    /// reason as the status ticker.
    private func syncCountdownTimer() {
        if menuIsOpen && countdownText() != nil {
            guard countdownTimer == nil else { return }
            let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.tickCountdown()
            }
            RunLoop.main.add(ticker, forMode: .common)
            countdownTimer = ticker
        } else {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    private func tickCountdown() {
        guard let text = countdownText() else { return }
        setInfoTitle(countdownItem, text, monospacedDigits: true)
    }

    /// `Auto-off in HH:MM:SS`, or nil when no deadline is showing. Never goes
    /// below zero: the watcher can take a few seconds to act after the deadline.
    private func countdownText() -> String? {
        guard let status, status.mode == "on", let until = status.until else { return nil }
        let left = max(0, until - Int(Date().timeIntervalSince1970))
        return String(format: "Auto-off in %02d:%02d:%02d", left / 3600, left / 60 % 60, left % 60)
    }

    // MARK: Construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        headlineItem = infoItem("", bold: true)
        contextItem = infoItem("")
        menu.addItem(headlineItem)
        menu.addItem(contextItem)

        countdownItem = infoItem("")
        watcherWarning = infoItem("")
        drainWarning = infoItem("")
        lpmWarning = infoItem("")
        for item in [countdownItem!, watcherWarning!, drainWarning!, lpmWarning!] {
            item.isHidden = true
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Explanations live in tooltips rather than inline. As part of the
        // item titles they were the widest thing in the menu, so they set the
        // width of every other row too.
        for (mode, title, help) in [
            ("auto", "Automatic",
             "Stay awake with the lid closed, but only while an external display is attached"),
            ("on", "Always Awake",
             "Stay awake with the lid closed even with no display attached — this drains the battery"),
            ("off", "Off",
             "Normal macOS behaviour: closing the lid sends the Mac to sleep"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.representedObject = mode
            item.toolTip = help
            modeItems[mode] = item
            menu.addItem(item)
        }

        menu.addItem(.separator())

        floorParent = submenuItem(
            "Battery floor",
            help: "While Always Awake, turn off once the battery is at or below this. Default 15%.",
            choices: [("10", "10%"), ("15", "15%"), ("20", "20%"), ("30", "30%"), ("off", "Off")],
            action: #selector(selectFloor(_:)),
            into: &floorItems
        )
        timerParent = submenuItem(
            "Auto-off",
            help: "While Always Awake, turn back off after this long. The clock starts when you turn Always Awake on.",
            choices: [("off", "Off"), ("60", "1 hour"), ("120", "2 hours")],
            action: #selector(selectTimer(_:)),
            into: &timerItems
        )
        menu.addItem(floorParent)
        menu.addItem(timerParent)

        lpmToggle = NSMenuItem(title: "Turn off in Low Power Mode",
                               action: #selector(toggleLowPowerMode(_:)), keyEquivalent: "")
        lpmToggle.target = self
        lpmToggle.isEnabled = true
        lpmToggle.toolTip = "While Always Awake and on battery, turn off when Low Power Mode is on. "
            + "Choosing Always Awake while it is already on keeps you awake until Low Power Mode ends. "
            + "The battery floor still applies."
        menu.addItem(lpmToggle)

        menu.addItem(.separator())

        loginToggle = NSMenuItem(title: "Open at Login",
                                 action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginToggle.target = self
        loginToggle.isEnabled = true
        menu.addItem(loginToggle)

        approvalWarning = infoItem("")
        approvalWarning.isHidden = true
        menu.addItem(approvalWarning)

        logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        // Routed through our own selector rather than NSApplication.terminate:.
        // macOS decorates the standard action with an icon, and an icon on any
        // item reserves an icon column for its whole section — which indents
        // every neighbouring row and leaves them out of line with the modes
        // above. Every item in this menu must stay icon-free to line up.
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp),
                                  keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        // Belt and braces: nothing here should carry an image.
        for item in menu.items + menu.items.flatMap({ $0.submenu?.items ?? [] })
        where item.image != nil {
            item.image = nil
        }

        return menu
    }

    /// A parent item with a fixed submenu of choices. Each choice carries its
    /// CLI argument in `representedObject`.
    private func submenuItem(_ title: String, help: String,
                             choices: [(value: String, title: String)],
                             action: Selector,
                             into store: inout [String: NSMenuItem]) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        for (value, choiceTitle) in choices {
            let item = NSMenuItem(title: choiceTitle, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.representedObject = value
            store[value] = item
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.isEnabled = true
        parent.toolTip = help
        parent.submenu = submenu
        return parent
    }

    private func infoItem(_ text: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        setInfoTitle(item, text, bold: bold)
        return item
    }

    /// Only touches the item when the text actually changed — re-setting an
    /// attributed title forces AppKit to re-measure, and re-measuring a menu
    /// that is on screen is what makes it jump.
    private func setInfoTitle(_ item: NSMenuItem, _ text: String, bold: Bool = false,
                              monospacedDigits: Bool = false) {
        guard item.title != text || item.attributedTitle == nil else { return }
        item.title = text
        // Fixed-width digits, so a ticking value does not resize the open menu.
        let font = bold
            ? NSFont.boldSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize)
            : monospacedDigits
                ? NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                : NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: bold ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
        )
    }

    private func setHidden(_ item: NSMenuItem, _ hidden: Bool) {
        if item.isHidden != hidden { item.isHidden = hidden }
    }

    /// Show or hide a warning, carrying its text with it so a hidden warning
    /// contributes nothing to the menu's measured width.
    private func setWarning(_ item: NSMenuItem, _ text: String, showing: Bool,
                            monospacedDigits: Bool = false) {
        if showing {
            setInfoTitle(item, text, monospacedDigits: monospacedDigits)
            setHidden(item, false)
        } else {
            setHidden(item, true)
            setInfoTitle(item, "", monospacedDigits: monospacedDigits)
        }
    }

    // MARK: State

    private func refresh() {
        probe.async { [weak self] in
            let fresh = CLI.status()
            DispatchQueue.main.async {
                self?.status = fresh
                self?.apply()
            }
        }
    }

    /// Push current state into the existing items. Never adds or removes any.
    private func apply() {
        updateIcon()

        // The daemon writes the log on its first state change, so before then
        // there is nothing to open. A menu item that does nothing when clicked
        // reads as broken, so grey it out and say why.
        let haveLog = FileManager.default.fileExists(atPath: Self.logPath)
        logItem.isEnabled = haveLog
        logItem.toolTip = haveLog ? Self.logPath : "No log yet — the watcher has not recorded a change"

        let loginOn = LoginItem.isEnabled
        loginToggle.state = loginOn ? .on : .off
        setWarning(approvalWarning, approvalWarningText, showing: LoginItem.needsApproval)

        guard CLI.isInstalled else {
            setInfoTitle(headlineItem, "clamshell CLI not found", bold: true)
            setInfoTitle(contextItem, "Run: sudo make install")
            setWarning(watcherWarning, watcherWarningText, showing: false)
            setWarning(drainWarning, drainWarningText, showing: false)
            setWarning(lpmWarning, lpmWarningText, showing: false)
            setWarning(countdownItem, "", showing: false, monospacedDigits: true)
            modeItems.values.forEach { $0.state = .off; $0.isEnabled = false }
            [floorParent, timerParent, lpmToggle].forEach { $0?.isEnabled = false }
            syncCountdownTimer()
            return
        }

        guard let status else {
            setInfoTitle(headlineItem, "Unable to read status", bold: true)
            setInfoTitle(contextItem, "clamshell json returned nothing")
            setWarning(watcherWarning, watcherWarningText, showing: false)
            setWarning(drainWarning, drainWarningText, showing: false)
            setWarning(lpmWarning, lpmWarningText, showing: false)
            setWarning(countdownItem, "", showing: false, monospacedDigits: true)
            modeItems.values.forEach { $0.state = .off; $0.isEnabled = false }
            [floorParent, timerParent, lpmToggle].forEach { $0?.isEnabled = false }
            syncCountdownTimer()
            return
        }

        setInfoTitle(headlineItem,
                     status.sleepDisabled ? "Lid closed → stays awake" : "Lid closed → sleeps",
                     bold: true)

        let displays = status.displays == 0
            ? "no display"
            : "\(status.displays) display\(status.displays == 1 ? "" : "s")"
        let lid = status.lidClosed ? "closed" : "open"
        let power = status.onBattery
            ? (status.batteryPercent.map { "battery \($0)%" } ?? "battery")
            : "AC power"
        setInfoTitle(contextItem, "\(displays) · \(lid) · \(power)")

        setWarning(watcherWarning, watcherWarningText, showing: !status.watcherRunning)
        let drainText = status.floor.map { "⚠︎ No display — off at \($0)%" } ?? drainWarningText
        setWarning(drainWarning, drainText,
                   showing: status.mode == "on" && status.displays == 0)
        setWarning(lpmWarning, lpmWarningText,
                   showing: status.lpmHold && status.mode == "on")

        let countdown = countdownText()
        setWarning(countdownItem, countdown ?? "", showing: countdown != nil, monospacedDigits: true)
        syncCountdownTimer()

        for (mode, item) in modeItems {
            item.isEnabled = true
            item.state = (mode == status.mode) ? .on : .off
        }

        // A custom value set from the CLI (say a 25% floor) matches no item,
        // so nothing is ticked.
        let floorKey = status.floor.map { String($0) } ?? "off"
        for (value, item) in floorItems { item.state = (value == floorKey) ? .on : .off }
        let timerKey = status.timerMinutes.map { String($0) } ?? "off"
        for (value, item) in timerItems { item.state = (value == timerKey) ? .on : .off }
        [floorParent, timerParent, lpmToggle].forEach { $0?.isEnabled = true }
        lpmToggle.state = status.lpmCut ? .on : .off
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let state: LaptopIcon.State
        let description: String

        if !CLI.isInstalled {
            state = .warning
            description = "clamshell is not installed"
        } else if let status, !status.watcherRunning {
            state = .warning
            description = "clamshell watcher is not running"
        } else if let status, status.sleepDisabled {
            state = .awake
            description = "Lid closed keeps this Mac awake"
        } else {
            state = .asleep
            description = "Lid closed sends this Mac to sleep"
        }

        button.image = LaptopIcon.image(for: state)
        button.toolTip = description
    }

    // MARK: Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }

        // Move the tick immediately; the watcher confirms a beat later.
        for (key, item) in modeItems { item.state = (key == mode) ? .on : .off }

        probe.async { [weak self] in
            CLI.set([mode])
            // The mode file changes at once, but the headline reflects the flag
            // the watcher actually applied, which lands about a second later.
            for delay in [0.0, 0.4, 1.0, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self?.refresh()
                }
            }
        }
    }

    /// Change a setting through the CLI, then re-read. These do not wait on
    /// the watcher, so a single refresh is enough.
    private func change(_ args: [String]) {
        probe.async { [weak self] in
            CLI.set(args)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc private func selectFloor(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        for (key, item) in floorItems { item.state = (key == value) ? .on : .off }
        change(["floor", value])
    }

    @objc private func selectTimer(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        for (key, item) in timerItems { item.state = (key == value) ? .on : .off }
        change(["timer", value])
    }

    @objc private func toggleLowPowerMode(_ sender: NSMenuItem) {
        let wanted = sender.state != .on
        sender.state = wanted ? .on : .off
        change(["lpm", wanted ? "on" : "off"])
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let wanted = !LoginItem.isEnabled
        sender.state = wanted ? .on : .off
        probe.async {
            LoginItem.setEnabled(wanted)
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func openLog() {
        guard FileManager.default.fileExists(atPath: Self.logPath) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: Self.logPath))
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
