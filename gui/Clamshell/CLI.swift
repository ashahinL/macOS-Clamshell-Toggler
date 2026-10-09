import Foundation
import ServiceManagement

// MARK: - Talking to the CLI

/// Mirrors `clamshell json`.
struct Status: Decodable {
    var version: String
    var mode: String
    var displays: Int
    var lidClosed: Bool
    var onBattery: Bool
    var sleepDisabled: Bool
    var watcherRunning: Bool
    var modeFile: String
    var batteryPercent: Int?
    var lowPowerMode: Bool
    var floor: Int?
    var timerMinutes: Int?
    var until: Int?
    var lpmCut: Bool
    var lpmHold: Bool
    var lastCut: String?
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

    /// Every setting is a file in the user's home, so no sudo.
    static func set(_ args: [String]) {
        guard isInstalled else { return }
        run(path, args)
    }
}

// MARK: - Open at login

/// `SMAppService`, falling back to a plain LaunchAgent when it throws.
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
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: break
        }
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Registered, but macOS wants the user to confirm it first.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
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
