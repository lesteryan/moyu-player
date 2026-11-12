// Usage: dock-scrcpy <index>
// index 0 = master: launches scrcpy, captures its window with a single SCStream,
//   renders every configured crop; its own crop goes to its Dock icon, other
//   crops are published as 128x128 BGRA frames via mmap'd files in /tmp.
// index >0 = viewer: pure reader — polls the mmap'd frame and sets its Dock
//   icon. Never touches ScreenCaptureKit (multiple streams on scrcpy's SDL
//   window proved fragile: -3805 races during window recreation, silently
//   frameless streams that poison the process's SCK connection).
import AppKit
import AVFoundation
import CoreMediaIO
import ScreenCaptureKit

let configPath = NSString("~/.config/dock-scrcpy.conf").expandingTildeInPath
let iconSize = 128
let fps: Double = 30

// Shared-memory frame format: [seq UInt64][reserved UInt64][BGRA 128*128*4]
let shmHeaderSize = 16
let shmPixelBytes = iconSize * iconSize * 4
let shmSize = shmHeaderSize + shmPixelBytes
func shmPath(_ i: Int) -> String { "/tmp/dock-scrcpy-frame-\(i).raw" }

// Serial queue for SCStream callbacks and every shm write: a concurrent queue
// overlaps callbacks (races on shared CGContexts, out-of-order shm writes), and
// placeholder broadcasts must not interleave with frame writes.
let captureQueue = DispatchQueue(label: "dock-scrcpy.capture")

struct CropRect {
    var w: Int, h: Int, x: Int, y: Int
    var string: String { "\(w):\(h):\(x):\(y)" }
    var dict: [String: Int] { ["w": w, "h": h, "x": x, "y": y] }

    static func parse(_ s: String) -> CropRect? {
        let p = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").compactMap { Int($0) }
        guard p.count == 4 else { return nil }
        return CropRect(w: p[0], h: p[1], x: p[2], y: p[3])
    }
    static func from(_ d: [String: Any]) -> CropRect? {
        guard let w = d["w"] as? Int, let h = d["h"] as? Int,
              let x = d["x"] as? Int, let y = d["y"] as? Int else { return nil }
        return CropRect(w: w, h: h, x: x, y: y)
    }
    static let defaultWindows: [CropRect] = [
        CropRect(w: 267, h: 534, x: 343, y: 200),
        CropRect(w: 267, h: 534, x: 610, y: 200),
    ]
}

func boundingBox(_ crops: [CropRect]) -> CropRect {
    let minX = crops.map(\.x).min()!
    let minY = crops.map(\.y).min()!
    let maxR = crops.map { $0.x + $0.w }.max()!
    let maxB = crops.map { $0.y + $0.h }.max()!
    return CropRect(w: maxR - minX, h: maxB - minY, x: minX, y: minY)
}

var turnScreenOffOnStart = true
var devicePreference = "auto"  // "auto" | "ios" | "android"
// Icon brightness gain applied when rendering (master only; viewers get the
// already-adjusted pixels via shm). Local only — the phone is never touched.
// Written on main (menu slider), read on captureQueue — a torn read is harmless.
var iconBrightness = 1.0
let iconBrightnessRange = 0.2...1.5

func loadConfig() -> [CropRect] {
    guard let data = FileManager.default.contents(atPath: configPath) else {
        return CropRect.defaultWindows
    }
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let v = json["turnScreenOff"] as? Bool { turnScreenOffOnStart = v }
        if let v = json["device"] as? String { devicePreference = v }
        if let v = json["brightness"] as? Double { iconBrightness = min(max(v, iconBrightnessRange.lowerBound), iconBrightnessRange.upperBound) }
        if let arr = json["windows"] as? [[String: Any]] {
            let crops = arr.compactMap { CropRect.from($0) }
            if !crops.isEmpty { return crops }
        }
    }
    if let text = String(data: data, encoding: .utf8) {
        let crops = text.components(separatedBy: "\n").compactMap { CropRect.parse($0) }
        if !crops.isEmpty {
            saveConfig(crops)
            return crops
        }
    }
    return CropRect.defaultWindows
}

func saveConfig(_ crops: [CropRect]) {
    var obj: [String: Any] = [
        "windows": crops.map(\.dict),
        "turnScreenOff": turnScreenOffOnStart,
    ]
    if devicePreference != "auto" { obj["device"] = devicePreference }
    if iconBrightness != 1.0 { obj["brightness"] = iconBrightness }
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? data.write(to: URL(fileURLWithPath: configPath))
}

var allCrops = loadConfig()

let myIndex: Int = {
    guard let arg = CommandLine.arguments.dropFirst().first, let idx = Int(arg) else { return 0 }
    return idx
}()
let isMaster = myIndex == 0

guard myIndex < allCrops.count else {
    FileHandle.standardError.write(Data("dock-scrcpy: index \(myIndex) out of range (have \(allCrops.count) windows)\n".utf8))
    exit(1)
}

// Single instance per index: a stray launch (clicking a leftover exec tile in
// the Dock, Finder, a second start.sh) would otherwise start a second master
// that kills the running scrcpy. flock is released by the kernel on any exit,
// so restarts never see a stale lock. O_CLOEXEC: scrcpy children must not
// inherit it, or an orphaned scrcpy would block the next master.
let instanceLockFD: Int32 = {
    let fd = open("/tmp/dock-scrcpy-\(myIndex).lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    if fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 {
        FileHandle.standardError.write(Data("dock-scrcpy[\(myIndex)]: already running — exiting\n".utf8))
        exit(0)
    }
    return fd
}()

let bbox = boundingBox(allCrops)

func log(_ s: String) { FileHandle.standardError.write(Data("dock-scrcpy[\(myIndex)]: \(s)\n".utf8)) }

let scrcpyDir: String = {
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let scriptDir = execURL.deletingLastPathComponent().path
    let candidate = scriptDir + "/../3rd/android-testing/scrcpy"
    if FileManager.default.fileExists(atPath: candidate + "/run") { return candidate }
    return ProcessInfo.processInfo.environment["SCRCPY_DIR"] ?? scriptDir
}()

// MARK: - Shared-memory frame buffer

final class FrameBuffer {
    private let ptr: UnsafeMutableRawPointer

    init?(index: Int, create: Bool) {
        let path = shmPath(index)
        let fd = create ? open(path, O_RDWR | O_CREAT, 0o644) : open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        if create { ftruncate(fd, off_t(shmSize)) }
        var st = stat()
        if fstat(fd, &st) != 0 || st.st_size < shmSize { close(fd); return nil }
        let prot = create ? PROT_READ | PROT_WRITE : PROT_READ
        guard let m = mmap(nil, shmSize, prot, MAP_SHARED, fd, 0), m != MAP_FAILED else {
            close(fd); return nil
        }
        close(fd)
        ptr = m
        // Reset seq when creating: a stale file from an older run (or protocol)
        // can hold an odd seq, which would permanently invert the seqlock parity
        // and make viewers reject every frame as "write in flight".
        if create { ptr.storeBytes(of: UInt64(0), toByteOffset: 0, as: UInt64.self) }
    }

    var seq: UInt64 { ptr.load(fromByteOffset: 0, as: UInt64.self) }

    // Seqlock: odd seq = write in progress. A plain post-increment lets a reader
    // that copies during the write (before seq changes) pass its recheck.
    func write(pixels: UnsafeRawPointer) {
        let start = seq &+ 1  // odd
        ptr.storeBytes(of: start, toByteOffset: 0, as: UInt64.self)
        OSMemoryBarrier()
        memcpy(ptr + shmHeaderSize, pixels, shmPixelBytes)
        OSMemoryBarrier()
        ptr.storeBytes(of: start &+ 1, toByteOffset: 0, as: UInt64.self)  // even: published
    }

    // Returns the frame's seq, or nil if a write was in flight (caller retries).
    func read(into buf: UnsafeMutableRawPointer) -> UInt64? {
        let s1 = seq
        guard s1 % 2 == 0 else { return nil }
        OSMemoryBarrier()
        memcpy(buf, ptr + shmHeaderSize, shmPixelBytes)
        OSMemoryBarrier()
        return seq == s1 ? s1 : nil
    }
}

func makeIconContext() -> CGContext {
    CGContext(data: nil, width: iconSize, height: iconSize, bitsPerComponent: 8,
              bytesPerRow: iconSize * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

// Placeholder icon: dark tile with a white SF Symbol (used for "waiting",
// "disconnected", "screen off" states so users see status instead of a frozen frame).
func placeholderContext(_ symbol: String) -> CGContext {
    let ctx = makeIconContext()
    ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: iconSize, height: iconSize))
    let cfg = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        .applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.85)]))
    if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let sz = sym.size
        let target = CGFloat(iconSize) * 0.5
        let s = min(target / max(sz.width, 1), target / max(sz.height, 1))
        let w = sz.width * s, h = sz.height * s
        sym.draw(in: NSRect(x: (CGFloat(iconSize) - w) / 2, y: (CGFloat(iconSize) - h) / 2, width: w, height: h),
                 from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current = prev
    }
    return ctx
}

func placeholderIcon(_ symbol: String) -> NSImage? {
    guard let cg = placeholderContext(symbol).makeImage() else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: iconSize, height: iconSize))
}

// Camouflage icons for screen-off: each Dock tile impersonates an innocent
// stock app (index 0 → Phone, index 1+ → Photos) instead of a telltale moon.
let sleepCamoApps = ["/System/Applications/Phone.app", "/System/Applications/Photos.app"]

func appIconContext(_ index: Int) -> CGContext? {
    let path = sleepCamoApps[min(index, sleepCamoApps.count - 1)]
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: path)
    let ctx = makeIconContext()
    ctx.clear(CGRect(x: 0, y: 0, width: iconSize, height: iconSize))
    let prev = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    icon.draw(in: NSRect(x: 0, y: 0, width: iconSize, height: iconSize),
              from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current = prev
    return ctx
}

// MARK: - ADB (master only)

let adbPath: String = {
    let sdk = NSString("~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath
    return FileManager.default.isExecutableFile(atPath: sdk) ? sdk : "/usr/bin/env"
}()

func runAdbData(_ args: [String]) -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: adbPath)
    p.arguments = adbPath.hasSuffix("env") ? ["adb"] + args : args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return Data() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}

@discardableResult
func runAdb(_ args: [String]) -> String {
    String(data: runAdbData(args), encoding: .utf8) ?? ""
}

func adbHasDevice() -> Bool {
    runAdb(["devices"])
        .split(separator: "\n").dropFirst()  // skip "List of devices attached"
        .contains { $0.hasSuffix("\tdevice") }
}

// Wait until adb sees a device. If none, restart the adb server and retry
// every 10s — recovers from USB disconnect/reconnect and wedged adb daemons.
// Loops forever: exiting non-2 would stop start.sh's restart loop entirely,
// so an overnight disconnect must never "give up".
func waitForAdbDevice() async {
    var attempts = 0
    while !adbHasDevice() {
        masterRenderer?.broadcastPlaceholder("iphone.slash")
        attempts += 1
        log("no adb device — restarting adb server, retrying in 10s... (attempt \(attempts))")
        runAdb(["kill-server"])
        runAdb(["start-server"])
        try? await Task.sleep(nanoseconds: 10_000_000_000)
    }
    log("adb device present")
}

// MARK: - Device screen on/off (master only)

// Panel-only off (device stays Awake, scrcpy keeps streaming) — the same call
// scrcpy-server makes for --turn-screen-off. Runtime toggling can't go through
// scrcpy's MOD+o shortcut: CGEvents posted to its background SDL window never
// reach it (verified, even with a full LAlt flagsChanged sequence). Instead run
// a tiny dex (screen-power/ScreenPower.java) via app_process that calls
// scrcpy-server's Device.setDisplayPower by reflection. Both jars are pushed
// under our own names: scrcpy deletes its server jar right after startup.
// Panel state is invisible to `dumpsys power` (wakefulness stays Awake) but the
// *Internal* display's powerMode in `dumpsys SurfaceFlinger --displays` flips
// On/Off. (scrcpy's own "scrcpy" virtual display always reads On — don't match it.)
// nil = unknown (no device / unrecognized dump) → menu enables both items.
// Main-thread only.
var devicePanelOn: Bool? = nil

func queryDevicePanelOn() -> Bool? {
    let out = runAdb(["shell", "dumpsys", "SurfaceFlinger", "--displays"])
    guard let d = out.range(of: "connectionType=Internal"),
          let p = out[d.upperBound...].range(of: "powerMode=") else { return nil }
    let mode = out[p.upperBound...].prefix { !$0.isWhitespace }
    return mode.hasPrefix("On")  // On / OnSuspend lit; Off / Doze / DozeSuspend dark
}

let screenPowerJar = "/data/local/tmp/dock-scrcpy-power.jar"
let screenPowerServerJar = "/data/local/tmp/dock-scrcpy-server.jar"

func pushScreenPowerJars() {
    let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().path
    runAdb(["push", execDir + "/screen-power/screen-power.jar", screenPowerJar])
    runAdb(["push", scrcpyDir + "/x/server/scrcpy-server", screenPowerServerJar])
}

// Idempotent: just applies the wanted state; the 5s poll re-reads the truth.
func setDevicePanel(on: Bool) {
    let out = runAdb(["shell", "CLASSPATH=\(screenPowerJar):\(screenPowerServerJar)",
                      "app_process", "/", "ScreenPower", on ? "on" : "off"])
    if out.contains("= true") {
        log("device panel turned \(on ? "on" : "off")")
    } else {
        // Fallback: real power key (sleep/wake); the poller then pauses/resumes capture.
        log("setDisplayPower failed (\(out.trimmingCharacters(in: .whitespacesAndNewlines))) — falling back to POWER key")
        let awake = runAdb(["shell", "dumpsys", "power"]).contains("mWakefulness=Awake")
        if awake != on { runAdb(["shell", "input", "keyevent", "26"]) }
    }
    let actual = queryDevicePanelOn()
    DispatchQueue.main.async { devicePanelOn = actual ?? on }
}

func turnDeviceScreenOn() { setDevicePanel(on: true) }

// MARK: - Scrcpy process (master only)

let scrcpyWindowTitle = "dock-scrcpy-src"
var scrcpyProc: Process?
var scrcpyWindowPID: pid_t = 0

func killStaleScrcpy() async {
    guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
    var killed = false
    for w in c.windows where w.title == scrcpyWindowTitle {
        if let pid = w.owningApplication?.processID {
            log("killing stale scrcpy pid \(pid)")
            killHard([pid])
            killed = true
        }
    }
    if killed { try? await Task.sleep(nanoseconds: 800_000_000) }
}

func launchScrcpy() {
    // A fully offscreen window (-32000) is never composited — SDL/Metal skips
    // rendering for occluded windows and SCK gets no frames. Keep 1px visible
    // in the bottom-right corner instead.
    let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    let winX = Int(screen.maxX) - 1
    let winY = Int(screen.maxY) - 1
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.currentDirectoryURL = URL(fileURLWithPath: scrcpyDir)
    var scrcpyArgs = "./run x --crop=\(bbox.string) --window-borderless --window-title=\(scrcpyWindowTitle) --window-x=\(winX) --window-y=\(winY) --max-fps=\(Int(fps))"
    if turnScreenOffOnStart { scrcpyArgs += " --turn-screen-off" }
    proc.arguments = ["-c", scrcpyArgs]
    var env = ProcessInfo.processInfo.environment
    env["SDL_MAC_BACKGROUND_APP"] = "1"  // accessory app: no Dock icon for scrcpy
    proc.environment = env
    proc.terminationHandler = { _ in
        // Device disconnect kills scrcpy. Exit 2 so start.sh relaunches us:
        // the fresh master waits for an adb device before starting scrcpy.
        DispatchQueue.main.async { masterFail("scrcpy exited (device disconnected?)") }
    }
    do {
        try proc.run()
    } catch {
        log("ERROR: failed to launch scrcpy: \(error)")
        dropDockTile()
        exit(1)
    }
    scrcpyProc = proc
    log("scrcpy launched --crop=\(bbox.string)")
}

// Drop the Dock tile before dying: a .regular app that exits abruptly can
// leave a ghost "exec" tile in the Dock.
func dropDockTile() {
    NSApp.setActivationPolicy(.accessory)
}

// scrcpy ignores SIGTERM (observed: still alive 15s later), so TERM first for
// a clean shutdown, then SIGKILL whatever survives 1s. An orphaned scrcpy keeps
// its window (same title) around and confuses the next master's window lookup.
func killHard(_ pids: [pid_t]) {
    let pids = pids.filter { $0 > 0 }
    guard !pids.isEmpty else { return }
    for pid in pids { kill(pid, SIGTERM) }
    for _ in 0..<10 {
        if pids.allSatisfy({ kill($0, 0) != 0 }) { return }
        usleep(100_000)
    }
    for pid in pids where kill(pid, 0) == 0 {
        log("pid \(pid) ignored SIGTERM — sending SIGKILL")
        kill(pid, SIGKILL)
    }
}

// A process and all its descendants (bash → run → scrcpy chain). Killing only
// the Process handle orphans scrcpy if it hasn't been resolved from the
// captured window yet (early startup).
func processTree(_ pid: pid_t) -> [pid_t] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-P", "\(pid)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").compactMap { pid_t($0) }.flatMap(processTree) + [pid]
}

func stopScrcpy() {
    scrcpyProc?.terminationHandler = nil  // avoid masterFail re-entry when we kill it ourselves
    var pids = [scrcpyWindowPID]
    if let proc = scrcpyProc, proc.isRunning { pids += processTree(proc.processIdentifier) }
    killHard(Array(Set(pids)))
}

// Exit code 2 asks start.sh to restart us: a fresh process is the only reliable
// recovery from a poisoned SCK connection.
func masterFail(_ reason: String) -> Never {
    log("FATAL: \(reason) — exiting for restart")
    masterRenderer?.broadcastPlaceholder("iphone.slash")
    dropDockTile()
    if isiOSMode {
        iosSession?.stopRunning()
        iosSession = nil
    } else {
        stopScrcpy()
    }
    exit(2)
}

// MARK: - Master: capture + render all crops

final class MasterRenderer: NSObject, SCStreamOutput, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let ctx = CIContext()
    private let crops: [CropRect]  // snapshot: bbox is fixed at launch, live edits must not desync
    private var iconCtxs: [CGContext] = []
    private var writers: [Int: FrameBuffer] = [:]
    private var loggedFirstFrame = false
    private(set) var frameCount = 0
    var bboxOverride: CropRect?

    override init() {
        crops = allCrops
        super.init()
        for i in crops.indices {
            iconCtxs.append(makeIconContext())
            if i != myIndex {
                if let fb = FrameBuffer(index: i, create: true) {
                    writers[i] = fb
                } else {
                    log("ERROR: cannot create frame buffer \(shmPath(i))")
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buf = sb.imageBuffer else { return }
        processFrame(CIImage(cvPixelBuffer: buf))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from conn: AVCaptureConnection) {
        guard let buf = sb.imageBuffer else { return }
        processFrame(CIImage(cvPixelBuffer: buf))
    }

    func processFrame(_ ci: CIImage) {
        frameCount += 1
        let fw = Int(ci.extent.width), fh = Int(ci.extent.height)
        if !loggedFirstFrame {
            loggedFirstFrame = true
            log("first frame: \(fw)x\(fh)")
            if isiOSMode {
                bboxOverride = CropRect(w: fw, h: fh, x: 0, y: 0)
                log("iOS bbox set to full screen: \(bboxOverride!.string)")
                for (i, crop) in crops.enumerated() {
                    if crop.x + crop.w > fw || crop.y + crop.h > fh {
                        log("WARNING: crop[\(i)] \(crop.string) exceeds device \(fw)x\(fh) — will be clamped")
                    }
                }
            }
        }
        if isiOSMode && (bboxOverride?.w != fw || bboxOverride?.h != fh) {
            bboxOverride = CropRect(w: fw, h: fh, x: 0, y: 0)
            log("iOS bbox updated: \(fw)x\(fh)")
        }
        let activeBBox = bboxOverride ?? bbox
        for (i, crop) in crops.enumerated() {
            guard let cg = croppedIcon(ci, crop: crop, bbox: activeBBox, iconCtx: iconCtxs[i]) else { continue }
            if i == myIndex {
                let img = NSImage(cgImage: cg, size: NSSize(width: iconSize, height: iconSize))
                DispatchQueue.main.async { NSApp.applicationIconImage = img }
            } else if let data = iconCtxs[i].data {
                writers[i]?.write(pixels: data)
            }
        }
    }

    // Push a status placeholder to own Dock icon and every viewer's shm buffer.
    // Callers are on the main thread; shm writes hop onto captureQueue so they
    // never interleave with in-flight frame writes from the stream callback.
    func broadcastPlaceholder(_ symbol: String) {
        let ctx = placeholderContext(symbol)
        if let data = ctx.data {
            captureQueue.sync {
                for fb in writers.values { fb.write(pixels: data) }
            }
        }
        guard let cg = ctx.makeImage() else { return }
        let img = NSImage(cgImage: cg, size: NSSize(width: iconSize, height: iconSize))
        if Thread.isMainThread { NSApp.applicationIconImage = img }
        else { DispatchQueue.main.async { NSApp.applicationIconImage = img } }
    }

    // Screen-off camouflage: each tile gets its stock-app disguise (falls back
    // to the moon placeholder if the app icon can't be loaded).
    func broadcastSleepCamo() {
        var ownCtx: CGContext?
        captureQueue.sync {
            for (i, fb) in writers {
                let ctx = appIconContext(i) ?? placeholderContext("moon.fill")
                if let data = ctx.data { fb.write(pixels: data) }
            }
        }
        ownCtx = appIconContext(myIndex) ?? placeholderContext("moon.fill")
        guard let cg = ownCtx?.makeImage() else { return }
        let img = NSImage(cgImage: cg, size: NSSize(width: iconSize, height: iconSize))
        if Thread.isMainThread { NSApp.applicationIconImage = img }
        else { DispatchQueue.main.async { NSApp.applicationIconImage = img } }
    }

    private func croppedIcon(_ ci: CIImage, crop: CropRect, bbox: CropRect, iconCtx: CGContext) -> CGImage? {
        let frameW = ci.extent.width, frameH = ci.extent.height
        let scaleX = frameW / CGFloat(max(bbox.w, 1))
        let scaleY = frameH / CGFloat(max(bbox.h, 1))
        let dx = CGFloat(crop.x - bbox.x) * scaleX
        let dy = CGFloat(crop.y - bbox.y) * scaleY
        let cw = CGFloat(crop.w) * scaleX
        let ch = CGFloat(crop.h) * scaleY
        let ciY = frameH - dy - ch

        var cropped = ci.cropped(to: CGRect(x: dx, y: ciY, width: cw, height: ch))
        guard !cropped.extent.isEmpty else { return nil }

        // Square-crop, downscale to 128, then render straight into the icon
        // bitmap (avoids an intermediate full-res CGImage readback per crop).
        let w = cropped.extent.width, h = cropped.extent.height
        if w != h {
            let side = min(w, h)
            let ox = cropped.extent.origin.x + (w - side) / 2
            let oy = cropped.extent.origin.y + (h - side) / 2
            cropped = cropped.cropped(to: CGRect(x: ox, y: oy, width: side, height: side))
        }
        let side = cropped.extent.width
        guard side > 0, let dst = iconCtx.data else { return nil }
        let s = CGFloat(iconSize) / side
        var img = cropped.transformed(by: CGAffineTransform(scaleX: s, y: s))
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.origin.x,
                                                    y: -img.extent.origin.y))
        let gain = CGFloat(iconBrightness)
        if gain != 1 {  // scale RGB, keep alpha; >1 clips at white on BGRA8 render
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            ])
        }
        ctx.render(img, toBitmap: dst, rowBytes: iconSize * 4,
                   bounds: CGRect(x: 0, y: 0, width: iconSize, height: iconSize),
                   format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return iconCtx.makeImage()
    }
}

// MARK: - iPhone capture (AVFoundation)

func enableiOSDeviceDiscovery() {
    var prop = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var yes: UInt32 = 1
    CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop,
                              0, nil, UInt32(MemoryLayout<UInt32>.size), &yes)
}

func findiOSDevice() -> AVCaptureDevice? {
    enableiOSDeviceDiscovery()
    let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    return devices.first { $0.modelID.contains("iPhone") || $0.modelID.contains("iPad") }
}

var iosSession: AVCaptureSession?

func startiOSCapture() async -> Bool {
    guard devicePreference != "android" else {
        log("device preference is android — skipping iOS detection")
        return false
    }
    guard let device = findiOSDevice() else { return false }
    log("iOS device found: \(device.localizedName) (\(device.modelID))")

    let session = AVCaptureSession()
    guard let input = try? AVCaptureDeviceInput(device: device) else {
        log("ERROR: cannot create AVCaptureDeviceInput for iOS device")
        return false
    }
    guard session.canAddInput(input) else {
        log("ERROR: cannot add iOS device input to session")
        return false
    }
    session.addInput(input)

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(masterRenderer!, queue: captureQueue)
    guard session.canAddOutput(output) else {
        log("ERROR: cannot add video output to session")
        return false
    }
    session.addOutput(output)
    session.startRunning()
    log("iOS capture session started — waiting for first frame...")

    // Async-wait for first frame: if the device needs "Trust This Computer"
    // or is otherwise unresponsive, we fall back to Android instead of
    // entering a restart loop.
    for _ in 0..<50 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        if masterRenderer!.frameCount > 0 { break }
    }
    if masterRenderer!.frameCount == 0 {
        log("no frames from iOS device after 5s — falling back to Android")
        session.stopRunning()
        return false
    }

    iosSession = session
    log("iOS capture confirmed (\(masterRenderer!.frameCount) frames)")
    return true
}

func startiOSWatchdog() {
    var lastCount = masterRenderer!.frameCount
    var staleChecks = 0
    let t = Timer(timeInterval: 5, repeats: true) { _ in
        let cur = masterRenderer!.frameCount
        if cur == lastCount {
            staleChecks += 1
            if staleChecks >= 2 {
                log("iOS capture stale for 10s — restarting")
                iosSession?.stopRunning()
                iosSession = nil
                masterFail("iOS device disconnected")
            }
        } else {
            staleChecks = 0
        }
        lastCount = cur
    }
    RunLoop.main.add(t, forMode: .common)
}

var isiOSMode = false

// Serial queue: SCStream on a concurrent queue may overlap callbacks — races
// on the shared CGContexts and out-of-order shm writes.
class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { scheduleRetry() }
    }
}

let streamDelegate = StreamDelegate()
let masterRenderer: MasterRenderer? = isMaster ? MasterRenderer() : nil  // viewers must not create frame files
var activeStream: SCStream?
var retryPending = false
var captureAttempts = 0
var screenOffPaused = false

func scheduleRetry() {
    guard !retryPending, !screenOffPaused else { return }
    retryPending = true
    activeStream = nil
    captureAttempts += 1
    if captureAttempts > 3 { masterFail("capture failed \(captureAttempts - 1) times") }
    log("retrying capture (attempt \(captureAttempts)/3)...")
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 500_000_000)
        retryPending = false
        await startCapture()
    }
}

// Wait until the scrcpy window exists with a stable identity: scrcpy recreates
// its window when the first video frame arrives, and a stream attached to the
// transient window dies with -3805 (or worse, goes silently frameless).
func findStableWindow() async -> SCWindow? {
    var lastID: CGWindowID = 0
    var lastSize = CGSize.zero
    var stablePolls = 0
    for i in 0..<240 {
        var cur: SCWindow?
        if let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
            cur = c.windows.first { $0.title == scrcpyWindowTitle && $0.frame.width > 1 && $0.frame.height > 1 }
        }
        if let w = cur, w.windowID == lastID, w.frame.size == lastSize {
            stablePolls += 1
            if stablePolls >= 6 { return w }  // unchanged for ~1.5s
        } else {
            stablePolls = 0
            lastID = cur?.windowID ?? 0
            lastSize = cur?.frame.size ?? .zero
        }
        if i % 20 == 0 { log("waiting for stable scrcpy window (\(i)/240)...") }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    return nil
}

func startCapture() async {
    guard let w = await findStableWindow() else {
        masterFail("scrcpy window not found")
    }
    log("window \(Int(w.frame.width))x\(Int(w.frame.height)) id=\(w.windowID) pid=\(w.owningApplication?.processID ?? 0)")
    if let pid = w.owningApplication?.processID { scrcpyWindowPID = pid }

    let filter = SCContentFilter(desktopIndependentWindow: w)
    let cfg = SCStreamConfiguration()
    let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    cfg.width = max(Int(w.frame.width * scale), 1)
    cfg.height = max(Int(w.frame.height * scale), 1)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.showsCursor = false

    do {
        let stream = SCStream(filter: filter, configuration: cfg, delegate: streamDelegate)
        try stream.addStreamOutput(masterRenderer!, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        activeStream = stream
        log("capturing bbox=\(bbox.string) at \(Int(fps))fps")
        // Watchdog: a healthy stream always delivers an initial frame quickly;
        // a silently dead one delivers nothing and no error.
        let baseline = masterRenderer!.frameCount
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard activeStream === stream else { return }
            if masterRenderer!.frameCount == baseline {
                log("no frames after 4s")
                try? await stream.stopCapture()
                scheduleRetry()
            } else {
                captureAttempts = 0
            }
        }
    } catch {
        log("startCapture error: \(error.localizedDescription)")
        scheduleRetry()
    }
}

// MARK: - Screen-off pause (master only)

// Poll device screen state via adb; when the screen is off, stop the capture
// stream (saves CPU/GPU) and show a moon placeholder. Resume when it's back on.
// Driven by mWakefulness, i.e. real sleep (physical power key / POWER fallback).
// Our panel-only off keeps the device Awake, so it never trips this; panel
// state for the menu is polled separately (queryDevicePanelOn).
func setScreenState(awake: Bool) {
    if !awake && !screenOffPaused && activeStream != nil {
        screenOffPaused = true
        let s = activeStream
        activeStream = nil
        Task { try? await s?.stopCapture() }
        masterRenderer?.broadcastSleepCamo()
        log("device screen off — capture paused")
    } else if awake && screenOffPaused {
        screenOffPaused = false
        log("device screen on — resuming capture")
        Task { @MainActor in await startCapture() }
    }
}

func startScreenStatePolling() {
    let t = Timer(timeInterval: 5, repeats: true) { _ in
        // Keepalive while paused: re-broadcast the camo icons so viewer seq
        // keeps moving and their 10s stale detector doesn't cry disconnect.
        if screenOffPaused { masterRenderer?.broadcastSleepCamo() }
        DispatchQueue.global().async {
            let out = runAdb(["shell", "dumpsys", "power"])
            guard out.contains("mWakefulness=") else { return }  // no device / unknown format
            let awake = out.contains("mWakefulness=Awake")
            let panelOn = queryDevicePanelOn()
            DispatchQueue.main.async {
                setScreenState(awake: awake)
                devicePanelOn = panelOn
            }
        }
    }
    RunLoop.main.add(t, forMode: .common)  // keep firing during event tracking
}

// MARK: - Viewer: poll shared memory

func viewerLoop() {
    var fb: FrameBuffer?
    var lastSeq: UInt64 = 0
    var lastChange = Date()
    var shownStale = false
    let pixels = UnsafeMutableRawPointer.allocate(byteCount: shmPixelBytes, alignment: 8)
    // Poll well above the frame rate: master pushes frames on its own clock, so
    // a free-running 30Hz poll adds up to a full frame of phase lag plus beat-
    // frequency judder against master's 30Hz. At 120Hz the seq check is just an
    // 8-byte load; pixels are copied only when the frame actually changed.
    let pollHz: Double = 120

    if let img = placeholderIcon("hourglass") { NSApp.applicationIconImage = img }

    let t = Timer(timeInterval: 1.0 / pollHz, repeats: true) { _ in
        if fb == nil {
            fb = FrameBuffer(index: myIndex, create: false)
            if fb == nil { return }  // master not up yet
            log("attached to \(shmPath(myIndex))")
        }
        guard let f = fb else { return }
        guard f.seq != lastSeq else {
            if !shownStale && Date().timeIntervalSince(lastChange) > 10 {
                shownStale = true
                log("no new frames for 10s (master gone?)")
                if let img = placeholderIcon("iphone.slash") { NSApp.applicationIconImage = img }
            }
            return
        }
        // nil = write in flight (torn); retry on the next 8ms tick.
        guard let seq = f.read(into: pixels), seq != lastSeq else { return }
        lastSeq = seq
        lastChange = Date()
        shownStale = false
        // Copy into an owned Data: a CGImage built directly over `pixels` is
        // copy-on-write against context draws only — our raw memcpy next tick
        // would mutate the image currently displayed in the Dock.
        let frame = Data(bytes: pixels, count: shmPixelBytes)
        guard let provider = CGDataProvider(data: frame as CFData),
              let cg = CGImage(width: iconSize, height: iconSize, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: iconSize * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return }
        NSApp.applicationIconImage = NSImage(cgImage: cg, size: NSSize(width: iconSize, height: iconSize))
    }
    RunLoop.main.add(t, forMode: .common)
}

// MARK: - Settings (master only)

// Drag-to-select a square crop on a device screenshot. Flipped coords so view
// y-down matches Android screen coordinates.
final class CropPickerView: NSView {
    private let image: NSImage
    private let devW: CGFloat, devH: CGFloat
    var onDrag: ((CropRect) -> Void)?
    var onSelect: ((CropRect) -> Void)?
    private var dragOrigin: CGPoint?
    private var sel: CGRect = .zero  // device coords

    override var isFlipped: Bool { true }

    init(image: NSImage, deviceSize: CGSize, viewSize: CGSize) {
        self.image = image
        devW = deviceSize.width
        devH = deviceSize.height
        super.init(frame: NSRect(origin: .zero, size: viewSize))
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    private var scale: CGFloat { min(bounds.width / devW, bounds.height / devH) }

    private func toDevice(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: max(0, min(devW, p.x / scale)), y: max(0, min(devH, p.y / scale)))
    }

    private var crop: CropRect {
        CropRect(w: Int(sel.width), h: Int(sel.height), x: Int(sel.origin.x), y: Int(sel.origin.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        image.draw(in: NSRect(x: 0, y: 0, width: devW * scale, height: devH * scale),
                   from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
        guard sel.width > 0 else { return }
        let r = NSRect(x: sel.origin.x * scale, y: sel.origin.y * scale,
                       width: sel.width * scale, height: sel.height * scale)
        NSColor.systemRed.withAlphaComponent(0.2).setFill()
        r.fill()
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: r)
        path.lineWidth = 2
        path.stroke()
    }

    override func mouseDown(with e: NSEvent) {
        dragOrigin = toDevice(e)
        sel = .zero
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let o = dragOrigin else { return }
        let p = toDevice(e)
        var side = max(abs(p.x - o.x), abs(p.y - o.y))  // square crops: non-square wastes sample area
        side = min(side, devW, devH)
        var x = p.x >= o.x ? o.x : o.x - side
        var y = p.y >= o.y ? o.y : o.y - side
        x = max(0, min(x, devW - side))
        y = max(0, min(y, devH - side))
        sel = CGRect(x: x, y: y, width: side, height: side)
        needsDisplay = true
        onDrag?(crop)
    }

    override func mouseUp(with e: NSEvent) {
        dragOrigin = nil
        if sel.width >= 16 { onSelect?(crop) }
    }
}

class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var pickerWindow: NSWindow?
    private var fields: [[NSTextField]] = []
    private var countControl: NSSegmentedControl!
    private var screenOffCheck: NSButton!
    private var windowWidgets: [[NSView]] = []  // per-window widget groups, for show/hide

    func showSettings() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        window = nil
        buildWindow()
    }

    private func buildWindow() {
        // The UI supports at least 2 windows and grows to fit a hand-edited
        // config with more — opening Settings must never silently drop crops.
        let maxWindows = max(2, allCrops.count)
        let blockH: CGFloat = 88  // per-window block: title + 2 field rows
        let pw: CGFloat = 340
        let ph: CGFloat = 138 + CGFloat(maxWindows) * blockH
        let content = NSView(frame: NSRect(x: 0, y: 0, width: pw, height: ph))

        let rowCount: CGFloat = ph - 32
        let rowScreen: CGFloat = ph - 58
        let rowBtn: CGFloat = 14

        let countLabel = NSTextField(labelWithString: "Windows:")
        countLabel.frame = NSRect(x: 20, y: rowCount, width: 70, height: 20)
        content.addSubview(countLabel)

        countControl = NSSegmentedControl(labels: (1...maxWindows).map(String.init), trackingMode: .selectOne, target: self, action: #selector(countChanged))
        countControl.frame = NSRect(x: 100, y: rowCount, width: CGFloat(maxWindows) * 50, height: 22)
        countControl.selectedSegment = min(allCrops.count, maxWindows) - 1
        content.addSubview(countControl)

        screenOffCheck = NSButton(checkboxWithTitle: "启动时关闭手机屏幕", target: nil, action: nil)
        screenOffCheck.frame = NSRect(x: 20, y: rowScreen, width: 200, height: 20)
        screenOffCheck.state = turnScreenOffOnStart ? .on : .off
        content.addSubview(screenOffCheck)

        fields = []
        windowWidgets = []

        for wi in 0..<maxWindows {
            let crop = wi < allCrops.count ? allCrops[wi]
                : CropRect.defaultWindows[min(wi, CropRect.defaultWindows.count - 1)]
            let titleY = ph - 88 - CGFloat(wi) * blockH
            let fieldRowA = titleY - 26
            let fieldRowB = titleY - 56

            let title = NSTextField(labelWithString: "Window \(wi + 1)")
            title.frame = NSRect(x: 20, y: titleY, width: 100, height: 18)
            title.font = .boldSystemFont(ofSize: 12)
            content.addSubview(title)

            let pickBtn = NSButton(title: "框选…", target: self, action: #selector(pickCrop(_:)))
            pickBtn.tag = wi
            pickBtn.bezelStyle = .rounded
            pickBtn.controlSize = .small
            pickBtn.frame = NSRect(x: 120, y: titleY - 3, width: 74, height: 24)
            content.addSubview(pickBtn)

            let labels = ["W:", "H:", "X:", "Y:"]
            let values = [crop.w, crop.h, crop.x, crop.y]
            var rowFields: [NSTextField] = []
            var groupWidgets: [NSView] = [title, pickBtn]

            for (j, (lab, val)) in zip(labels, values).enumerated() {
                let col = j % 2
                let fy = j < 2 ? fieldRowA : fieldRowB
                let lx = CGFloat(20 + col * 155)

                let l = NSTextField(labelWithString: lab)
                l.frame = NSRect(x: lx, y: fy, width: 22, height: 22)
                l.alignment = .right
                content.addSubview(l)

                let f = NSTextField(frame: NSRect(x: lx + 26, y: fy, width: 90, height: 22))
                f.stringValue = "\(val)"
                f.formatter = NumberFormatter()
                content.addSubview(f)

                rowFields.append(f)
                groupWidgets.append(contentsOf: [l, f])
            }

            fields.append(rowFields)
            windowWidgets.append(groupWidgets)
        }
        updateVisibility()

        let applyBtn = NSButton(title: "Apply", target: self, action: #selector(applySettings))
        applyBtn.frame = NSRect(x: 110, y: rowBtn, width: 80, height: 28)
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"
        content.addSubview(applyBtn)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(closeSettings))
        cancelBtn.frame = NSRect(x: 200, y: rowBtn, width: 80, height: 28)
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        content.addSubview(cancelBtn)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: pw, height: ph),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "dock-scrcpy Settings"
        win.contentView = content
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    private func updateVisibility() {
        let count = countControl.selectedSegment + 1
        for (wi, group) in windowWidgets.enumerated() {
            group.forEach { $0.isHidden = wi >= count }
        }
    }

    @objc func countChanged() { updateVisibility() }

    // Screenshot the device and let the user drag-select the crop area.
    @objc func pickCrop(_ sender: NSButton) {
        let wi = sender.tag
        sender.isEnabled = false
        DispatchQueue.global().async {
            let data = runAdbData(["exec-out", "screencap", "-p"])
            DispatchQueue.main.async {
                sender.isEnabled = true
                guard let img = NSImage(data: data), let rep = img.representations.first,
                      rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
                    log("screencap failed (no device?)")
                    NSSound.beep()
                    return
                }
                self.showPicker(image: img,
                                deviceSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh),
                                windowIndex: wi)
            }
        }
    }

    private func showPicker(image: NSImage, deviceSize: CGSize, windowIndex: Int) {
        pickerWindow?.close()
        let s = min(480 / deviceSize.width, 760 / deviceSize.height, 1)
        let viewSize = CGSize(width: deviceSize.width * s, height: deviceSize.height * s)
        let previewPane: CGFloat = 148
        let totalSize = CGSize(width: viewSize.width + previewPane, height: max(viewSize.height, 180))

        let container = NSView(frame: NSRect(origin: .zero, size: totalSize))
        let picker = CropPickerView(image: image, deviceSize: deviceSize, viewSize: viewSize)
        picker.setFrameOrigin(NSPoint(x: 0, y: totalSize.height - viewSize.height))
        container.addSubview(picker)

        // Live 128×128 preview: what the selection will look like as a Dock icon.
        let preview = NSImageView(frame: NSRect(x: viewSize.width + 10, y: totalSize.height - 138,
                                                width: 128, height: 128))
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = CGColor(gray: 0.1, alpha: 1)
        preview.layer?.cornerRadius = 22  // approximate Dock tile rounding
        preview.layer?.masksToBounds = true
        container.addSubview(preview)

        let hint = NSTextField(labelWithString: "Dock 预览")
        hint.frame = NSRect(x: viewSize.width + 10, y: totalSize.height - 160, width: 128, height: 16)
        hint.alignment = .center
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        container.addSubview(hint)

        let devW = deviceSize.width, devH = deviceSize.height
        let renderPreview: (CropRect) -> Void = { c in
            guard c.w > 0 else { return }
            let out = NSImage(size: NSSize(width: 128, height: 128))
            out.lockFocus()
            let sx = image.size.width / devW, sy = image.size.height / devH
            let from = NSRect(x: CGFloat(c.x) * sx, y: (devH - CGFloat(c.y) - CGFloat(c.h)) * sy,
                              width: CGFloat(c.w) * sx, height: CGFloat(c.h) * sy)
            image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128),
                       from: from, operation: .copy, fraction: 1)
            out.unlockFocus()
            preview.image = out
        }

        let win = NSWindow(contentRect: NSRect(origin: .zero, size: totalSize),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "拖拽框选 Window \(windowIndex + 1)"
        win.isReleasedWhenClosed = false
        picker.onDrag = { [weak win] c in
            win?.title = "\(c.w)×\(c.h) @ (\(c.x), \(c.y))"
            renderPreview(c)
        }
        picker.onSelect = { [weak self, weak win] c in
            guard let self, windowIndex < self.fields.count else { return }
            let f = self.fields[windowIndex]
            f[0].integerValue = c.w
            f[1].integerValue = c.h
            f[2].integerValue = c.x
            f[3].integerValue = c.y
            win?.close()
        }
        win.contentView = container
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pickerWindow = win
    }

    @objc func applySettings() {
        let count = countControl.selectedSegment + 1
        var crops: [CropRect] = []
        for i in 0..<count {
            let f = fields[i]
            let c = CropRect(w: f[0].integerValue, h: f[1].integerValue,
                             x: f[2].integerValue, y: f[3].integerValue)
            guard c.w > 0, c.h > 0, c.x >= 0, c.y >= 0 else {
                NSSound.beep()
                log("invalid crop for window \(i + 1): \(c.string) — not saved")
                return
            }
            crops.append(c)
        }
        turnScreenOffOnStart = screenOffCheck.state == .on
        allCrops = crops
        saveConfig(crops)
        // Exit 2: start.sh restarts master (and viewers) with the new config.
        log("settings saved: \(crops.map(\.string)) — restarting to apply")
        dropDockTile()
        stopScrcpy()
        exit(2)
    }

    @objc func closeSettings() { window?.close() }
    func windowWillClose(_ notification: Notification) { window = nil }
}

var settingsController: SettingsWindowController?

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationDidFinishLaunching(_ n: Notification) {
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !isiOSMode {
            let crop = allCrops[myIndex]
            let cx = crop.x + crop.w / 2
            let cy = crop.y + crop.h / 2
            DispatchQueue.global().async { runAdb(["shell", "input", "tap", "\(cx)", "\(cy)"]) }
        }
        return false
    }

    func applicationWillTerminate(_ n: Notification) {
        dropDockTile()
        if isiOSMode {
            iosSession?.stopRunning()
        } else if isMaster {
            stopScrcpy()
            turnDeviceScreenOn()
        }
    }

    func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        if !isiOSMode {
            appMenu.addItem(withTitle: "黑屏", action: #selector(toggleScreen), keyEquivalent: "d")
            appMenu.addItem(.separator())
        }
        if isMaster {
            appMenu.addItem(makeBrightnessItem())
            appMenu.addItem(.separator())
        }
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit dock-scrcpy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    // Menu row = sun symbol + slider. Continuous: purely local, takes effect on
    // the next frame. Persisted on mouse-up (Apply/restart would otherwise reset it).
    private func makeBrightnessItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        let icon = NSImageView(frame: NSRect(x: 14, y: 5, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "亮度")
        icon.contentTintColor = .secondaryLabelColor
        let slider = NSSlider(value: iconBrightness, minValue: iconBrightnessRange.lowerBound,
                              maxValue: iconBrightnessRange.upperBound,
                              target: self, action: #selector(brightnessChanged(_:)))
        slider.frame = NSRect(x: 40, y: 4, width: 166, height: 20)
        slider.isContinuous = true
        view.addSubview(icon)
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @objc func brightnessChanged(_ sender: NSSlider) {
        iconBrightness = sender.doubleValue
        if NSApp.currentEvent?.type == .leftMouseUp { saveConfig(allCrops) }
    }

    // Single toggle item: title follows the polled panel state.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleScreen) {
            switch devicePanelOn {
            case true?: item.title = "黑屏"
            case false?: item.title = "亮屏"
            case nil: item.title = "切换黑屏"
            }
        }
        return true
    }

    // Re-query the device at click time so a stale poll can't flip the wrong way.
    @objc func toggleScreen() {
        let cached = devicePanelOn
        DispatchQueue.global().async {
            let on = queryDevicePanelOn() ?? cached ?? true
            setDevicePanel(on: !on)
        }
    }

    @objc func openSettings() {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController!.showSettings()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let appDel = AppDelegate()
app.delegate = appDel

// Signal handling via DispatchSource (C signal handlers must not call dispatch APIs).
// SIGHUP too: closing the terminal running start.sh sends HUP, whose default
// action kills us without dropping the Dock tile → ghost tile left behind.
let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM, SIGHUP].map { sig in
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { NSApp.terminate(nil) }
    src.resume()
    return src
}

if isMaster {
    Task { @MainActor in
        masterRenderer?.broadcastPlaceholder("hourglass")
        if await startiOSCapture() {
            isiOSMode = true
            startiOSWatchdog()
            log("running in iOS mode (no scrcpy, no adb)")
        } else {
            log("no iOS device — falling back to Android/scrcpy")
            await killStaleScrcpy()
            await waitForAdbDevice()
            pushScreenPowerJars()
            if turnScreenOffOnStart { devicePanelOn = false }
            launchScrcpy()
            await startCapture()
            startScreenStatePolling()
        }
        appDel.setupMenu()
    }
} else {
    DispatchQueue.main.async { viewerLoop() }
}

app.run()
