import AppKit
import Foundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var status: Status?
    private var lastCutSeen: String?
    private var haveCutBaseline = false

    private let popover = NSPopover()
    private var lastClose = Date.distantPast
    /// Bumped on every change from the panel, so a status read that started
    /// before it is dropped instead of undoing it.
    private var edits = 0
    private let model = PanelModel(state: PanelState(
        cliInstalled: false, status: nil, loginOn: false, loginNeedsApproval: false, haveLog: false
    ))

    private static let openInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 15

    private static let logPath = "/var/log/clamshell.log"

    private let probe = DispatchQueue(label: "local.clamshell.probe", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        let hosting = NSHostingController(rootView: Panel(model: model, actions: makeActions()))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // One blocking read at launch so the first open is already correct.
        status = CLI.status()
        noteCut(status)
        apply()

        startTicker(interval: Self.idleInterval)
    }

    /// Deliberately on `.common` rather than the default run loop mode: while
    /// a picker's pop-up menu is open AppKit runs in event-tracking mode, and
    /// a plain scheduled timer is starved for as long as it stays open.
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
    }

    /// A transient popover closes itself on the mouse-down of a click on the
    /// icon, and the button's action then fires on mouse-up. Without the
    /// time check that click would reopen the panel it was meant to close.
    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard Date().timeIntervalSince(lastClose) > 0.3,
              let button = statusItem.button else { return }
        apply()
        refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverWillShow(_ notification: Notification) {
        startTicker(interval: Self.openInterval)
    }

    func popoverWillClose(_ notification: Notification) {
        lastClose = Date()
    }

    func popoverDidClose(_ notification: Notification) {
        startTicker(interval: Self.idleInterval)
    }

    // MARK: State

    private func refresh() {
        let started = edits
        probe.async { [weak self] in
            let fresh = CLI.status()
            DispatchQueue.main.async {
                guard let self, self.edits == started else { return }
                self.status = fresh
                self.noteCut(fresh)
                self.apply()
            }
        }
    }

    /// The first good read only sets the baseline: an old cutoff is already over, so it must not notify.
    private func noteCut(_ status: Status?) {
        guard let status else { return }
        guard haveCutBaseline else {
            lastCutSeen = status.lastCut
            haveCutBaseline = true
            return
        }
        guard status.lastCut != lastCutSeen else { return }
        lastCutSeen = status.lastCut
        guard let line = status.lastCut, let message = cutMessage(line) else { return }
        probe.async {
            CLI.run("/usr/bin/osascript", ["-e", "on run argv",
                                           "-e", "display notification (item 1 of argv) with title \"Clamshell\"",
                                           "-e", "end run",
                                           message])
        }
    }

    private func cutMessage(_ line: String) -> String? {
        let fields = line.split(separator: " ")
        guard let kind = fields.first else { return nil }
        switch kind {
        case "floor":
            if fields.count > 2 { return "Battery at \(fields[2])%. Clamshell turned off." }
            return "Battery low. Clamshell turned off."
        case "timer":
            return "Auto-off timer ended. Clamshell turned off."
        case "lpm":
            return "Low Power Mode is on. Clamshell turned off."
        default:
            return nil
        }
    }

    private func apply() {
        updateIcon()
        let installed = CLI.isInstalled
        model.state = PanelState(
            cliInstalled: installed,
            status: installed ? status : nil,
            loginOn: LoginItem.isEnabled,
            loginNeedsApproval: LoginItem.needsApproval,
            haveLog: FileManager.default.fileExists(atPath: Self.logPath)
        )
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
        } else if let status, status.sleepDisabled, status.mode == "on", status.onBattery {
            state = .armed
            description = armedTooltip(status)
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

    private func armedTooltip(_ status: Status) -> String {
        var cutoffs: [String] = []
        if let floor = status.floor { cutoffs.append("at \(floor)%") }
        if status.timerMinutes != nil { cutoffs.append("when the timer ends") }
        if status.lpmCut && !status.lpmHold { cutoffs.append("in Low Power Mode") }

        switch cutoffs.count {
        case 0:
            return "Awake on battery. Nothing will turn it off."
        case 1:
            return "Awake on battery. Off \(cutoffs[0])."
        case 2:
            return "Awake on battery. Off \(cutoffs[0]), or \(cutoffs[1])."
        default:
            return "Awake on battery. Off \(cutoffs[0]), \(cutoffs[1]), or \(cutoffs[2])."
        }
    }

    // MARK: Actions

    private func makeActions() -> PanelActions {
        PanelActions(
            setMode: { [weak self] mode in
                self?.status?.mode = mode
                self?.edits += 1
                self?.apply()
                self?.probe.async {
                    CLI.set([mode])
                    // The mode file changes at once, but the headline reflects the flag
                    // the watcher actually applied, which lands about a second later.
                    for delay in [0.0, 0.4, 1.0, 2.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self?.refresh()
                        }
                    }
                }
            },
            setFloor: { [weak self] value in
                self?.status?.floor = value == "off" ? nil : Int(value)
                self?.change(["floor", value])
            },
            setTimer: { [weak self] value in
                self?.status?.timerMinutes = value == "off" ? nil : Int(value)
                self?.status?.until = nil
                self?.change(["timer", value])
            },
            setLowPowerMode: { [weak self] on in
                self?.status?.lpmCut = on
                self?.change(["lpm", on ? "on" : "off"])
            },
            setLogin: { [weak self] on in
                self?.model.state.loginOn = on
                self?.probe.async {
                    LoginItem.setEnabled(on)
                    DispatchQueue.main.async { self?.apply() }
                }
            },
            openLog: { [weak self] in
                self?.popover.performClose(nil)
                guard FileManager.default.fileExists(atPath: Self.logPath) else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: Self.logPath))
            },
            quit: { NSApp.terminate(nil) }
        )
    }

    private func change(_ args: [String]) {
        edits += 1
        apply()
        probe.async { [weak self] in
            CLI.set(args)
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}
