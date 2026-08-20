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

    /// Switching modes only rewrites a file in the user's home — no sudo.
    static func setMode(_ mode: String) {
        guard isInstalled else { return }
        run(path, [mode])
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
    private var status: Status?

    /// Status is read by spawning the CLI, so it happens off the main thread.
    /// A menu that blocks on a subprocess while it is opening visibly hitches.
    private let probe = DispatchQueue(label: "local.clamshell.probe", qos: .utility)

    // Built once and then only updated. Rebuilding a live NSMenu makes it
    // resize under the cursor, so the item set has to stay fixed.
    private var headlineItem: NSMenuItem!
    private var contextItem: NSMenuItem!
    private var watcherWarning: NSMenuItem!
    private var drainWarning: NSMenuItem!
    private var approvalWarning: NSMenuItem!
    private var loginToggle: NSMenuItem!

    // Warning text is applied only while the warning is showing. `isHidden`
    // stops an item drawing but AppKit still measures its title, so a hidden
    // item with a long string silently pads the whole menu's width.
    private let watcherWarningText = "⚠︎ Watcher not running"
    private let drainWarningText = "⚠︎ No display — battery will drain"
    private let approvalWarningText = "⚠︎ Approve in Login Items"
    private var modeItems: [String: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self

        // One blocking read at launch so the first open is already correct.
        status = CLI.status()
        apply()

        // Deliberately on .common rather than the default run loop mode: while
        // a menu is open AppKit runs in event-tracking mode, and a plain
        // scheduled timer is starved for exactly as long as the user is
        // looking at it — which is the one moment the contents must be live.
        let ticker = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    /// Called before the menu is laid out. Applies what is already known, then
    /// kicks off a refresh — no structural change, so nothing resizes.
    func menuNeedsUpdate(_ menu: NSMenu) {
        apply()
        refresh()
    }

    // MARK: Construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        headlineItem = infoItem("", bold: true)
        contextItem = infoItem("")
        menu.addItem(headlineItem)
        menu.addItem(contextItem)

        watcherWarning = infoItem("")
        drainWarning = infoItem("")
        for item in [watcherWarning!, drainWarning!] {
            item.isHidden = true
            menu.addItem(item)
        }

        menu.addItem(.separator())

        for (mode, title, subtitle) in [
            ("auto", "Automatic", "Awake only with a display"),
            ("on", "Always Awake", "Even with no display"),
            ("off", "Off", "Normal macOS sleep"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.representedObject = mode

            let attributed = NSMutableAttributedString(
                string: title,
                attributes: [.font: NSFont.menuFont(ofSize: 0)]
            )
            attributed.append(NSAttributedString(
                string: "  \(subtitle)",
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
            item.attributedTitle = attributed

            modeItems[mode] = item
            menu.addItem(item)
        }

        menu.addItem(.separator())

        loginToggle = NSMenuItem(title: "Open at Login",
                                 action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginToggle.target = self
        loginToggle.isEnabled = true
        menu.addItem(loginToggle)

        approvalWarning = infoItem("")
        approvalWarning.isHidden = true
        menu.addItem(approvalWarning)

        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        logItem.isEnabled = true
        menu.addItem(logItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        return menu
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
    private func setInfoTitle(_ item: NSMenuItem, _ text: String, bold: Bool = false) {
        guard item.title != text || item.attributedTitle == nil else { return }
        item.title = text
        let font = bold
            ? NSFont.boldSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize)
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
    private func setWarning(_ item: NSMenuItem, _ text: String, showing: Bool) {
        if showing {
            setInfoTitle(item, text)
            setHidden(item, false)
        } else {
            setHidden(item, true)
            setInfoTitle(item, "")
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

        let loginOn = LoginItem.isEnabled
        loginToggle.state = loginOn ? .on : .off
        setWarning(approvalWarning, approvalWarningText, showing: LoginItem.needsApproval)

        guard CLI.isInstalled else {
            setInfoTitle(headlineItem, "clamshell CLI not found", bold: true)
            setInfoTitle(contextItem, "Run: sudo make install")
            setWarning(watcherWarning, watcherWarningText, showing: false)
            setWarning(drainWarning, drainWarningText, showing: false)
            modeItems.values.forEach { $0.state = .off; $0.isEnabled = false }
            return
        }

        guard let status else {
            setInfoTitle(headlineItem, "Unable to read status", bold: true)
            setInfoTitle(contextItem, "clamshell json returned nothing")
            setWarning(watcherWarning, watcherWarningText, showing: false)
            setWarning(drainWarning, drainWarningText, showing: false)
            modeItems.values.forEach { $0.state = .off; $0.isEnabled = false }
            return
        }

        setInfoTitle(headlineItem,
                     status.sleepDisabled ? "Lid closed → stays awake" : "Lid closed → sleeps",
                     bold: true)

        let displays = status.displays == 0
            ? "No external display"
            : "\(status.displays) external display\(status.displays == 1 ? "" : "s")"
        let lid = status.lidClosed ? "lid closed" : "lid open"
        let power = status.onBattery ? "battery" : "AC power"
        setInfoTitle(contextItem, "\(displays) · \(lid) · \(power)")

        setWarning(watcherWarning, watcherWarningText, showing: !status.watcherRunning)
        setWarning(drainWarning, drainWarningText,
                   showing: status.mode == "on" && status.displays == 0)

        for (mode, item) in modeItems {
            item.isEnabled = true
            item.state = (mode == status.mode) ? .on : .off
        }
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
            CLI.setMode(mode)
            // The mode file changes at once, but the headline reflects the flag
            // the watcher actually applied, which lands about a second later.
            for delay in [0.0, 0.4, 1.0, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self?.refresh()
                }
            }
        }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let wanted = !LoginItem.isEnabled
        sender.state = wanted ? .on : .off
        probe.async {
            LoginItem.setEnabled(wanted)
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
    }

    @objc private func openLog() {
        let log = URL(fileURLWithPath: "/var/log/clamshell.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
