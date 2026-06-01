import Cocoa
import IOKit
import IOKit.hid

// Path to the single state file written by the Claude Code hooks.
// Contains exactly one word: "busy" or "idle".
let stateFile = ("~/.claude/openlid.state" as NSString).expandingTildeInPath

// Master on/off switch, flipped by ctl.sh (`/openlid on|off`).
// Contains "0" when disabled; anything else (or missing) means enabled.
let enableFlag = ("~/.claude/openlid.enabled" as NSString).expandingTildeInPath

func isEnabled() -> Bool {
    let v = (try? String(contentsOfFile: enableFlag, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return v != "0"
}

// ---- Lid angle sensor ----------------------------------------------------
// The only trigger. Present on 14"/16" MacBook Pro and MacBook Air from
// M2/2022 onward (NOT the M1 Air). We poll the angle and fire *before* the lid
// reaches sleep, so the alarm is seen/heard in time even on battery.
// Device: Apple VID 0x05AC / PID 0x8104, HID Sensor page 0x20, Orientation
// usage 0x8A; angle read from Feature report 1 as (byte2<<8)|byte1.
let closeAngle = 45.0   // fire the alarm when the lid drops to/below this angle
let rearmAngle = 60.0   // re-arm (allow firing again) once the lid opens past this
var lidSensor: IOHIDDevice?
var armed = true        // false after firing, until the lid reopens past rearmAngle

func findLidAngleSensor() -> IOHIDDevice? {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Int] = [
        kIOHIDVendorIDKey: 0x05AC,
        kIOHIDProductIDKey: 0x8104,
        kIOHIDPrimaryUsagePageKey: 0x0020,
        kIOHIDPrimaryUsageKey: 0x008A,
    ]
    IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    defer { IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) }
    guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return nil }
    for dev in devices where IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
        return dev
    }
    return nil
}

func readLidAngle() -> Double? {
    guard let dev = lidSensor else { return nil }
    var report = [UInt8](repeating: 0, count: 8)
    var len: CFIndex = report.count
    // Report ID 1 is the sensor's angle feature report (per the reference
    // implementations); byte 0 is the report ID, bytes 1-2 are the angle.
    let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, &report, &len)
    guard r == kIOReturnSuccess, len >= 3 else { return nil }
    return Double(UInt16(report[2]) << 8 | UInt16(report[1]))
}

func readState() -> String {
    (try? String(contentsOfFile: stateFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "idle"
}

func writeState(_ s: String) {
    try? s.write(toFile: stateFile, atomically: true, encoding: .utf8)
}

// Treat the moment as a clean slate: no turn is in progress, and the next lid
// close should be silent until a new prompt marks it busy again.
func resetToIdle() {
    writeState("idle")
    armed = true
}

// A "busy" marker is only trusted if it was touched recently. Hooks refresh it
// on every prompt and tool call, so an active turn stays fresh; but a session
// killed mid-turn (kill -9, closed terminal) never writes "idle" — without this
// guard a stale "busy" would make the lid alarm fire forever. (Wake-from-sleep
// also resets the marker; see below.) Raise this if you run single tools longer
// than 10 min with no tool calls in between.
let staleSeconds = 600.0
func busyAndFresh() -> Bool {
    guard readState() == "busy" else { return false }
    guard let mtime = (try? FileManager.default
        .attributesOfItem(atPath: stateFile))?[.modificationDate] as? Date else { return true }
    return Date().timeIntervalSince(mtime) <= staleSeconds
}

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// Starts a child process without blocking, returning it so we can wait/kill later.
func spawn(_ path: String, _ args: [String]) -> Process? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    do { try p.run() } catch { return nil }
    return p
}

// How long the alarm flashes/sounds.
let alarmSeconds = 5.0

// Borderless red overlays, one per screen.
var overlays: [NSWindow] = []

func showRedScreen() {
    overlays.removeAll()
    for screen in NSScreen.screens {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = true
        w.backgroundColor = .red
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.red.cgColor

        let label = NSTextField(labelWithString: "CLAUDE IS WORKING\nDON'T CLOSE THE LID")
        label.font = .systemFont(ofSize: 64, weight: .heavy)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (screen.frame.width  - label.frame.width)  / 2,
                                     y: (screen.frame.height - label.frame.height) / 2)
        view.addSubview(label)
        w.contentView = view
        w.orderFrontRegardless()
        overlays.append(w)
    }
}

func hideRedScreen() {
    for w in overlays { w.orderOut(nil) }
    overlays.removeAll()
}

// Fires the alarm: full-screen blinking red overlay + max-volume sound + speech.
// Pumps the run loop so the windows actually draw.
var alarmActive = false
func alarm() {
    if alarmActive { return }   // ignore re-entry while an alarm is already showing
    alarmActive = true
    defer { alarmActive = false }

    showRedScreen()
    defer { hideRedScreen() }

    // Force max volume so the alarm is heard even if muted; always restore it.
    let prevVol = run("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"])
    run("/usr/bin/osascript", ["-e", "set volume output volume 100"])
    defer {
        if Int(prevVol) != nil {
            run("/usr/bin/osascript", ["-e", "set volume output volume \(prevVol)"])
        }
    }

    let sound = spawn("/usr/bin/afplay", ["/System/Library/Sounds/Sosumi.aiff"])
    let voice = spawn("/usr/bin/say", ["Claude is working. Do not close the lid."])
    defer { sound?.terminate(); voice?.terminate() }

    let end = Date().addingTimeInterval(alarmSeconds)
    var bright = true
    while Date() < end {
        CFRunLoopRunInMode(.defaultMode, 0.25, false)   // pump so the screen draws
        bright.toggle()
        let color = (bright ? NSColor.red : NSColor.black).cgColor
        for w in overlays { w.contentView?.layer?.backgroundColor = color }
    }
}

// `openlid test` fires the alarm once and exits — for trying the overlay
// without actually putting the machine to sleep.
if CommandLine.arguments.contains("test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    alarm()
    exit(0)
}

// `openlid preview` holds a steady, silent red screen for 12s — handy for taking
// a screenshot (⌘⇧3) without the blink or the alarm sound.
if CommandLine.arguments.contains("preview") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    showRedScreen()
    let end = Date().addingTimeInterval(12)
    while Date() < end { CFRunLoopRunInMode(.defaultMode, 0.2, false) }
    exit(0)
}

// Initialize AppKit so this background tool can draw the red overlay.
// .accessory = no Dock icon / menu bar.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

// Poll the lid angle and warn while the lid is closing on a busy session.
lidSensor = findLidAngleSensor()
if lidSensor == nil {
    FileHandle.standardError.write(Data(
        "OpenLid: no lid angle sensor on this Mac — alarm will not fire here.\n".utf8))
}
print("OpenLid running. Watching \(stateFile)")

// Reset to idle on every "fresh start" so an interrupted turn never leaves the
// alarm armed:
//   - process launch  -> covers reboot / login / agent reload
//   - wake from sleep  -> the common closed-then-reopened case
//   - displays waking  -> e.g. clamshell display sleep without full sleep
resetToIdle()
let wsCenter = NSWorkspace.shared.notificationCenter
for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
    wsCenter.addObserver(forName: name, object: nil, queue: .main) { _ in resetToIdle() }
}

Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    guard let angle = readLidAngle() else { return }
    if angle >= rearmAngle { armed = true }
    if armed, angle <= closeAngle, isEnabled(), busyAndFresh() {
        armed = false
        alarm()
    }
}

CFRunLoopRun()
