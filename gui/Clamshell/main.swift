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
    static func run(_ arguments: [String]) -> String? {
        guard isInstalled else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
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
        guard let output = run(["json"]),
              let data = output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }

    /// Switching modes only rewrites a file in the user's home — no sudo.
    static func setMode(_ mode: String) {
        run([mode])
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

        // The watcher polls every 10s; matching that keeps the icon honest
        // without doing meaningful work.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    /// Rebuild just before the menu is shown, so it is never stale on click.
    func menuWillOpen(_ menu: NSMenu) {
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

        let symbol: String
        let description: String

        if !CLI.isInstalled {
            symbol = "exclamationmark.triangle.fill"
            description = "clamshell is not installed"
        } else if let status, !status.watcherRunning {
            symbol = "exclamationmark.triangle.fill"
            description = "clamshell watcher is not running"
        } else if let status, status.sleepDisabled {
            symbol = "display"
            description = "Lid closed keeps this Mac awake"
        } else {
            symbol = "moon.zzz.fill"
            description = "Lid closed sends this Mac to sleep"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = description
    }

    private func rebuildMenu() {
        let menu = statusItem.menu ?? NSMenu()
        menu.removeAllItems()

        guard CLI.isInstalled else {
            addInfo(to: menu, "clamshell CLI not found")
            addInfo(to: menu, "Run: sudo ./scripts/install.sh")
            menu.addItem(.separator())
            addQuit(to: menu)
            return
        }

        guard let status else {
            addInfo(to: menu, "Unable to read status")
            menu.addItem(.separator())
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
            addInfo(to: menu, "⚠︎ Watcher not running")
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

    private func addQuit(to menu: NSMenu) {
        let item = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        CLI.setMode(mode)

        // The watcher needs a moment to notice the new mode file.
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refresh()
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
