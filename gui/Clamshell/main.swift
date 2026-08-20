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

/// A closed MacBook, drawn rather than borrowed from SF Symbols — there is no
/// stock symbol for a shut lid, which is the one thing this app is about.
/// Filled means "closing the lid keeps this Mac awake".
enum LidIcon {
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

        let size = NSSize(width: 18, height: 13)
        let filled = (state == .awake)

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()

            // The closed machine: one thin slab with the lid seam across it.
            let body = NSBezierPath(
                roundedRect: NSRect(x: 1.5, y: 3.8, width: 15.0, height: 4.4),
                xRadius: 1.3, yRadius: 1.3
            )
            let seam = NSBezierPath()
            seam.move(to: NSPoint(x: 2.6, y: 6.0))
            seam.line(to: NSPoint(x: 15.4, y: 6.0))

            if filled {
                body.fill()
                // Punch the seam out of the solid slab so it still reads as a
                // laptop rather than a plain block.
                NSGraphicsContext.current?.compositingOperation = .clear
                seam.lineWidth = 0.9
                seam.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                body.lineWidth = 1.2
                body.stroke()
                seam.lineWidth = 0.9
                seam.stroke()
            }

            // The desk it sits on, so the shape reads as a laptop and not a box.
            NSColor.black.set()
            let desk = NSBezierPath()
            desk.move(to: NSPoint(x: 0.5, y: 2.2))
            desk.line(to: NSPoint(x: 17.5, y: 2.2))
            desk.lineWidth = 1.1
            desk.lineCapStyle = .round
            desk.stroke()

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        refresh()

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

    /// Rebuild before the menu is laid out, so it is never stale on open.
    ///
    /// This has to be `menuNeedsUpdate` and not `menuWillOpen`: the latter runs
    /// after AppKit has already sized and laid out the items, so edits made
    /// there may not show until the next time the menu is opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    // MARK: State

    private func refresh() {
        status = CLI.status()
        updateIcon()
        rebuildMenu()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let state: LidIcon.State
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

        button.image = LidIcon.image(for: state)
        button.toolTip = description
    }

    private func rebuildMenu() {
        let menu = statusItem.menu ?? NSMenu()
        menu.removeAllItems()

        guard CLI.isInstalled else {
            addInfo(to: menu, "clamshell CLI not found", bold: true)
            addInfo(to: menu, "Run: sudo make install")
            menu.addItem(.separator())
            addLoginItemToggle(to: menu)
            addQuit(to: menu)
            return
        }

        guard let status else {
            addInfo(to: menu, "Unable to read status", bold: true)
            menu.addItem(.separator())
            addLoginItemToggle(to: menu)
            addQuit(to: menu)
            return
        }

        // Headline: the one thing the user actually wants to know.
        let headline = status.sleepDisabled
            ? "Lid closed → stays awake"
            : "Lid closed → sleeps"
        addInfo(to: menu, headline, bold: true)

        let displayText = status.displays == 0
            ? "No external display"
            : "\(status.displays) external display\(status.displays == 1 ? "" : "s")"
        let power = status.onBattery ? "battery" : "AC power"
        addInfo(to: menu, "\(displayText) · \(status.lidClosed ? "lid closed" : "lid open") · \(power)")

        if !status.watcherRunning {
            addInfo(to: menu, "⚠︎ Watcher not running — run: sudo make install")
        }
        if status.mode == "on" && status.displays == 0 {
            addInfo(to: menu, "⚠︎ Awake with no display — will drain battery")
        }

        menu.addItem(.separator())

        addModeItem(to: menu, title: "Automatic", subtitle: "Awake only with a display",
                    mode: "auto", current: status.mode)
        addModeItem(to: menu, title: "Always Awake", subtitle: "Even with no display",
                    mode: "on", current: status.mode)
        addModeItem(to: menu, title: "Off", subtitle: "Normal macOS sleep",
                    mode: "off", current: status.mode)

        menu.addItem(.separator())

        addLoginItemToggle(to: menu)

        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        addQuit(to: menu)
    }

    // MARK: Menu builders

    private func addInfo(to menu: NSMenu, _ text: String, bold: Bool = false) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = bold
            ? NSFont.menuBarFont(ofSize: 0)
            : NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: font.pointSize) : font,
                .foregroundColor: bold ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
        )
        menu.addItem(item)
    }

    private func addModeItem(to menu: NSMenu, title: String, subtitle: String,
                             mode: String, current: String) {
        let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mode
        item.state = (mode == current) ? .on : .off

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

        menu.addItem(item)
    }

    private func addLoginItemToggle(to menu: NSMenu) {
        let item = NSMenuItem(title: "Open at Login",
                              action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        item.target = self
        item.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(item)

        if LoginItem.needsApproval {
            addInfo(to: menu, "⚠︎ Approve in System Settings → Login Items")
        }
    }

    private func addQuit(to menu: NSMenu) {
        let item = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        CLI.setMode(mode)
        refresh()

        // The mode file changes at once, but the headline reflects the flag the
        // watcher actually applied — which lands about a second later. Poll
        // across that window so the icon and headline settle without waiting
        // for the next tick.
        for delay in [0.3, 0.8, 1.5, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        refresh()
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
