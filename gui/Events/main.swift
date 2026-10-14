// clamshell-events: watches macOS event sources and prints one line per burst
// of real changes. It decides nothing; bin/clamshell --watch and the menu bar
// app read its output.
//
//   clamshell-events --parent <pid> <config-dir>
//
// Lines: `ready <pid>`, `alive`, or sorted reasons from
// `config lid displays settings power lpm wake`.
import Foundation
import IOKit
import IOKit.pwr_mgt
import notify

let args = CommandLine.arguments
guard args.count == 4, args[1] == "--parent", let parent = pid_t(args[2]), parent > 0 else {
    FileHandle.standardError.write("usage: clamshell-events --parent <pid> <config-dir>\n".data(using: .utf8)!)
    exit(64)
}
let configDir = args[3]

signal(SIGPIPE, SIG_IGN)

// The only reliable SleepDisabled reader is private. Without it this helper
// cannot report settings changes, so it exits and the watcher keeps polling.
typealias CopyFn = @convention(c) () -> Unmanaged<CFDictionary>?
let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
guard let copySym = dlsym(iokit, "IOPMCopySystemPowerSettings") else {
    FileHandle.standardError.write("clamshell-events: IOPMCopySystemPowerSettings missing\n".data(using: .utf8)!)
    exit(1)
}
let copySettings = unsafeBitCast(copySym, to: CopyFn.self)

// ---- parent watch
let kq = kqueue()
var procEvent = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                       fflags: NOTE_EXIT, data: 0, udata: nil)
guard kq >= 0, kevent(kq, &procEvent, 1, nil, 0, nil) == 0 else { exit(1) }
let parentSource = DispatchSource.makeReadSource(fileDescriptor: kq, queue: .main)
parentSource.setEventHandler { exit(0) }
parentSource.resume()

// ---- output
func emit(_ line: String) {
    let bytes = Array((line + "\n").utf8)
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBufferPointer { write(1, $0.baseAddress, $0.count) }
        if n < 0 { exit(0) }
        off += n
    }
}

var pending = Set<String>()
func report(_ reason: String) {
    if pending.isEmpty {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            emit(pending.sorted().joined(separator: " "))
            pending.removeAll()
        }
    }
    pending.insert(reason)
}

// ---- snapshot
let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

func readDisplays() -> Int? {
    var it: io_iterator_t = 0
    let match = ["IOPropertyExistsMatch": "SinkDeviceOUI"] as NSDictionary as CFDictionary
    guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return nil }
    var n = 0
    var s = IOIteratorNext(it)
    while s != 0 { n += 1; IOObjectRelease(s); s = IOIteratorNext(it) }
    IOObjectRelease(it)
    return n
}

func readLid() -> String {
    guard let v = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool else { return "unknown" }
    return v ? "closed" : "open"
}

func readSleepDisabled() -> String {
    guard let d = copySettings()?.takeRetainedValue() as? [String: Any], let v = d["SleepDisabled"] else { return "unknown" }
    return "\(v)"
}

var lastDisplays: Int?
var lastLid = ""
var lastSleepDisabled = ""

func takeSnapshot() {
    lastDisplays = readDisplays()
    lastLid = readLid()
    lastSleepDisabled = readSleepDisabled()
}

func recheck() {
    let displays = readDisplays(), lid = readLid(), sleepDisabled = readSleepDisabled()
    if displays != lastDisplays { report("displays") }
    if lid != lastLid { report("lid") }
    if sleepDisabled != lastSleepDisabled { report("settings") }
    lastDisplays = displays; lastLid = lid; lastSleepDisabled = sleepDisabled
}

// ---- config dir and files
func watch(_ path: String, _ mask: DispatchSource.FileSystemEvent,
           onEvent: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
    s.setEventHandler { onEvent(s.data) }
    s.setCancelHandler { close(fd) }
    s.resume()
    return s
}

var dirSource: DispatchSourceFileSystemObject?
var fileSources: [DispatchSourceFileSystemObject] = []

func armFiles() {
    fileSources.forEach { $0.cancel() }
    fileSources = ((try? FileManager.default.contentsOfDirectory(atPath: configDir)) ?? []).compactMap { name in
        watch(configDir + "/" + name, [.write, .extend, .rename, .delete, .attrib]) { _ in
            report("config")
            armFiles()
        }
    }
}

func armDir() -> Bool {
    dirSource = watch(configDir, [.write, .rename, .delete]) { events in
        report("config")
        if !events.isDisjoint(with: [.delete, .rename]) {
            dirSource?.cancel()
            dirSource = nil
        }
        armFiles()
    }
    guard dirSource != nil else { return false }
    armFiles()
    return true
}

_ = armDir()

// ---- 5 s check
let checkTimer = DispatchSource.makeTimerSource(queue: .main)
checkTimer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
checkTimer.setEventHandler {
    recheck()
    if dirSource == nil, armDir() { report("config") }
}
checkTimer.resume()

// ---- IOKit notifications
let port = IONotificationPortCreate(kIOMainPortDefault)!
IONotificationPortSetDispatchQueue(port, .main)

// Fires on every lid close and open, but also on charger plug and wake;
// recheck reports only a changed value.
var lidNote: io_object_t = 0
IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { _, _, type, _ in
    if type == 0xE003_4100 { recheck() }
}, nil, &lidNote)

func drain(_ it: io_iterator_t) {
    var s = IOIteratorNext(it)
    while s != 0 { IOObjectRelease(s); s = IOIteratorNext(it) }
}

// SinkDeviceOUI appears after the display service does, so first-match on it
// never fires on plug. The framebuffer and DCP classes do; recount at +1 s and
// +3 s to catch the property once it lands.
let displaysCallback: IOServiceMatchingCallback = { _, it in
    drain(it)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { recheck() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { recheck() }
}
var displayIterators: [io_iterator_t] = []
func armDisplays(_ type: String, _ match: CFDictionary) {
    var it: io_iterator_t = 0
    guard IOServiceAddMatchingNotification(port, type, match, displaysCallback, nil, &it) == KERN_SUCCESS else { return }
    drain(it)
    displayIterators.append(it)
}
for cls in ["IOMobileFramebufferShim", "DCPAVServiceProxy"] {
    armDisplays(kIOFirstMatchNotification, IOServiceMatching(cls))
    armDisplays(kIOTerminatedNotification, IOServiceMatching(cls))
}
armDisplays(kIOTerminatedNotification, ["IOPropertyExistsMatch": "SinkDeviceOUI"] as NSDictionary as CFDictionary)

// Private, so optional: the 5 s check covers SleepDisabled without it.
typealias RegFn = @convention(c) (DispatchQueue, @convention(block) () -> Void) -> UnsafeMutableRawPointer?
var prefsHandle: UnsafeMutableRawPointer?
if let sym = dlsym(iokit, "IOPMRegisterPrefsChangeNotification") {
    prefsHandle = unsafeBitCast(sym, to: RegFn.self)(.main) { recheck() }
}

// ---- power source, Low Power Mode
var notifyTokens: [Int32] = []
for name in ["com.apple.system.powersources.source", "com.apple.system.powersources.percent"] {
    var tok: Int32 = 0
    if notify_register_dispatch(name, &tok, .main, { _ in report("power") }) == NOTIFY_STATUS_OK {
        notifyTokens.append(tok)
    }
}

let lpmObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                                         object: nil, queue: .main) { _ in report("lpm") }

// ---- wake
var rootConn: io_connect_t = 0
var pmNotifier: io_object_t = 0
var pmPort: IONotificationPortRef?
rootConn = IORegisterForSystemPower(nil, &pmPort, { _, _, type, arg in
    switch type {
    case 0xE000_0270, 0xE000_0280:
        // Registering for system power makes us a sleep participant: every
        // sleep waits up to 30 s for this answer.
        IOAllowPowerChange(rootConn, Int(bitPattern: arg))
    case 0xE000_0300:
        recheck()
        report("wake")
    default:
        break
    }
}, &pmNotifier)
if let pmPort { IONotificationPortSetDispatchQueue(pmPort, .main) }

// ---- heartbeat, so the reader can spot a stalled helper
let aliveTimer = DispatchSource.makeTimerSource(queue: .main)
aliveTimer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(1))
aliveTimer.setEventHandler { emit("alive") }
aliveTimer.resume()

takeSnapshot()
if getppid() != parent { exit(1) }
emit("ready \(getpid())")

withExtendedLifetime((parentSource, checkTimer, lidNote, displayIterators, prefsHandle,
                      notifyTokens, lpmObserver, pmNotifier, aliveTimer)) {
    CFRunLoopRun()
}
