import SwiftUI

// MARK: - Panel

struct PanelState {
    var cliInstalled: Bool
    var status: Status?          // nil = `clamshell json` failed
    var loginOn: Bool
    var loginNeedsApproval: Bool
    var haveLog: Bool
}

struct PanelActions {
    var setMode: (String) -> Void          // "auto" | "on" | "off"
    var setFloor: (String) -> Void         // "10" | "15" | "20" | "30" | "off" (CLI arg)
    var setTimer: (String) -> Void         // "off" | "60" | "120"  (minutes, CLI arg)
    var setLowPowerMode: (Bool) -> Void
    var setLogin: (Bool) -> Void
    var openLog: () -> Void
    var quit: () -> Void
}

final class PanelModel: ObservableObject {
    @Published var state: PanelState
    init(state: PanelState) { self.state = state }
}

/// Renders `model.state` and reports changes through `actions`. Bindings
/// never write to the model: what the panel shows always comes from the CLI.
struct Panel: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions

    private struct Choice: Hashable {
        let value: String
        let title: String
    }

    private static let pickerWidth: CGFloat = 110

    private var state: PanelState { model.state }

    /// Status from a CLI that is no longer installed is stale, so ignore it.
    private var status: Status? { state.cliInstalled ? state.status : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            modeSection
            Divider()
            cutoffSection
            Divider()
            appSection
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.headline)
            Text(context)
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(warnings, id: \.self) { warning($0) }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Mode", selection: Binding(get: { status?.mode ?? "" }, set: actions.setMode)) {
                Text("Automatic").tag("auto")
                Text("Always Awake").tag("on")
                Text("Off").tag("off")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(status == nil)

            if let hint = modeHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cutoffSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("When Always Awake")
                    .textCase(.uppercase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Turns Always Awake back off. Applies on battery only, except the timer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            row("Auto-off") {
                Picker("Auto-off", selection: Binding(get: { timerKey }, set: actions.setTimer)) {
                    ForEach(timerChoices, id: \.self) { Text($0.title).tag($0.value) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: Self.pickerWidth, alignment: .trailing)
            }

            if let until = countdownUntil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.countdown(until: until, now: context.date))
                        .monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            }

            row("Battery floor") {
                Picker("Battery floor", selection: Binding(get: { floorKey }, set: actions.setFloor)) {
                    ForEach(floorChoices, id: \.self) { Text($0.title).tag($0.value) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: Self.pickerWidth, alignment: .trailing)
            }

            row("Turn off in Low Power Mode") {
                toggle(Binding(get: { status?.lpmCut ?? false }, set: actions.setLowPowerMode))
            }
        }
        .disabled(status == nil)
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Open at Login") {
                toggle(Binding(get: { state.loginOn }, set: actions.setLogin))
            }
            if state.loginNeedsApproval {
                warning("Approve in Login Items")
            }
            HStack {
                Button("Open Log", action: actions.openLog)
                    .disabled(!state.haveLog)
                Spacer()
                Button("Quit", action: actions.quit)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    // MARK: Pieces

    private func row<Control: View>(_ title: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        Row(title: title, control: control())
    }

    /// `.disabled` greys the control but not a plain `Text` beside it.
    private struct Row<Control: View>: View {
        @Environment(\.isEnabled) private var isEnabled
        let title: String
        let control: Control

        var body: some View {
            HStack {
                Text(title)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                Spacer()
                control
            }
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(text)
        }
        .font(.callout)
    }

    // MARK: Text

    private var headline: String {
        guard state.cliInstalled else { return "clamshell CLI not found" }
        guard let status else { return "Unable to read status" }
        return status.sleepDisabled ? "Lid closed → stays awake" : "Lid closed → sleeps"
    }

    private var context: String {
        guard state.cliInstalled else { return "Run: sudo make install" }
        guard let status else { return "clamshell json returned nothing" }
        let displays = status.displays == 0
            ? "no display"
            : "\(status.displays) display\(status.displays == 1 ? "" : "s")"
        let lid = status.lidClosed ? "closed" : "open"
        let power = status.onBattery
            ? (status.batteryPercent.map { "battery \($0)%" } ?? "battery")
            : "AC power"
        return "\(displays) · lid \(lid) · \(power)"
    }

    private var warnings: [String] {
        guard let status else { return [] }
        var list: [String] = []
        if !status.watcherRunning {
            list.append("Watcher not running")
        }
        if status.mode == "on" && status.displays == 0 {
            list.append(status.floor.map { "No display: off at \($0)%" } ?? "No display: battery will drain")
        }
        if status.lpmHold && status.mode == "on" {
            list.append("Low Power Mode is on: staying awake")
        }
        return list
    }

    private var modeHint: String? {
        switch status?.mode {
        case "auto": return "Stays awake with the lid closed only while a display is attached."
        case "on": return "Stays awake with the lid closed, even with no display. This drains the battery."
        case "off": return "Closing the lid puts the Mac to sleep, as normal."
        default: return nil
        }
    }

    private var countdownUntil: Int? {
        guard let status, status.mode == "on" else { return nil }
        return status.until
    }

    /// Clamped at zero: the watcher can take a few seconds to act after the
    /// deadline.
    private static func countdown(until: Int, now: Date) -> String {
        let left = max(0, until - Int(now.timeIntervalSince1970))
        return String(format: "Off in %02d:%02d:%02d", left / 3600, left / 60 % 60, left % 60)
    }

    // MARK: Choices

    // A value set from the CLI (say a 25% floor) gets its own entry, so the
    // picker shows the true setting rather than a wrong one or a blank.

    private var floorKey: String { status?.floor.map { String($0) } ?? "off" }

    private var floorChoices: [Choice] {
        var percents = [10, 15, 20, 30]
        if let floor = status?.floor, !percents.contains(floor) {
            percents.append(floor)
            percents.sort()
        }
        return percents.map { Choice(value: String($0), title: "\($0)%") }
            + [Choice(value: "off", title: "Off")]
    }

    private var timerKey: String { status?.timerMinutes.map { String($0) } ?? "off" }

    private var timerChoices: [Choice] {
        var minutes = [60, 120]
        if let timer = status?.timerMinutes, !minutes.contains(timer) {
            minutes.append(timer)
            minutes.sort()
        }
        return [Choice(value: "off", title: "Off")]
            + minutes.map { Choice(value: String($0), title: Self.duration($0)) }
    }

    private static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
