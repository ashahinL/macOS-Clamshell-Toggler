import AppKit
import SwiftUI

// Drawn through a real offscreen window with `cacheDisplay` rather than
// SwiftUI's `ImageRenderer`, which draws AppKit-backed controls (pickers,
// switches) as placeholder boxes.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/preview"
let now = Int(Date().timeIntervalSince1970)

func sample(mode: String, displays: Int = 0, lidClosed: Bool = false,
            batteryPercent: Int? = nil, sleepDisabled: Bool = false,
            watcherRunning: Bool = true, lowPowerMode: Bool = false,
            floor: Int? = 15, timerMinutes: Int? = nil, until: Int? = nil,
            lpmCut: Bool = true, lpmHold: Bool = false) -> Status {
    Status(version: "1.3.0", mode: mode, displays: displays, lidClosed: lidClosed,
           onBattery: batteryPercent != nil, sleepDisabled: sleepDisabled,
           watcherRunning: watcherRunning, modeFile: "~/.config/clamshell/mode",
           batteryPercent: batteryPercent, lowPowerMode: lowPowerMode, floor: floor,
           timerMinutes: timerMinutes, until: until, lpmCut: lpmCut, lpmHold: lpmHold,
           lastCut: nil)
}

func state(_ status: Status?, cliInstalled: Bool = true,
           loginNeedsApproval: Bool = false) -> PanelState {
    PanelState(cliInstalled: cliInstalled, status: status, loginOn: true,
               loginNeedsApproval: loginNeedsApproval, haveLog: true)
}

let samples: [(name: String, state: PanelState)] = [
    ("1-off-ac", state(sample(mode: "off"))),
    ("2-on-timer", state(sample(mode: "on", batteryPercent: 72, sleepDisabled: true,
                                timerMinutes: 30, until: now + 1778))),
    ("3-on-warnings", state(sample(mode: "on", batteryPercent: 40, sleepDisabled: true,
                                   watcherRunning: false, lowPowerMode: true, lpmHold: true),
                            loginNeedsApproval: true)),
    ("4-custom-values", state(sample(mode: "on", displays: 1, lidClosed: true,
                                     batteryPercent: 60, sleepDisabled: true,
                                     floor: 25, timerMinutes: 45, until: now + 600))),
    ("5-no-cli", state(nil, cliInstalled: false)),
]

let noActions = PanelActions(
    setMode: { _ in }, setFloor: { _ in }, setTimer: { _ in },
    setLowPowerMode: { _ in }, setLogin: { _ in }, openLog: {}, quit: {}
)

final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

func render(_ state: PanelState, appearance: NSAppearance, to path: String) {
    let host = NSHostingView(rootView: Panel(model: PanelModel(state: state), actions: noActions))
    host.appearance = appearance
    let fitting = host.fittingSize
    let frame = NSRect(x: 0, y: 0, width: ceil(fitting.width), height: ceil(fitting.height))
    host.frame = frame

    let backdrop = Backdrop(frame: frame)
    backdrop.addSubview(host)

    let window = NSWindow(contentRect: frame.offsetBy(dx: -10_000, dy: -10_000),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance
    window.backgroundColor = .windowBackgroundColor
    window.contentView = backdrop
    backdrop.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    backdrop.displayIfNeeded()

    let scale = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(frame.width) * scale, pixelsHigh: Int(frame.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("no bitmap for \(path)") }
    rep.size = frame.size
    backdrop.cacheDisplay(in: backdrop.bounds, to: rep)

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("no PNG for \(path)")
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        fatalError("cannot write \(path): \(error)")
    }
    print("wrote \(path)")
}

_ = NSApplication.shared

for (name, state) in samples {
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        guard let appearance = NSAppearance(named: appearanceName) else { continue }
        render(state, appearance: appearance, to: "\(outDir)/\(name)-\(suffix).png")
    }
}
