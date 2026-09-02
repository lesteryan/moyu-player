// Usage: dock-scrcpy <index>
// index 0 = master: launches scrcpy, captures its window with a single SCStream,
//   renders every configured crop; its own crop goes to its Dock icon, other
//   crops are published as 128x128 BGRA frames via mmap'd files in /tmp.
// index >0 = viewer: pure reader — polls the mmap'd frame and sets its Dock
//   icon. Never touches ScreenCaptureKit (multiple streams on scrcpy's SDL
//   window proved fragile: -3805 races during window recreation, silently
//   frameless streams that poison the process's SCK connection).
import AppKit
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

func loadCrops() -> [CropRect] {
    guard let data = FileManager.default.contents(atPath: configPath) else {
        return CropRect.defaultWindows
    }
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let arr = json["windows"] as? [[String: Any]] {
        let crops = arr.compactMap { CropRect.from($0) }
        if !crops.isEmpty { return crops }
    }
    if let text = String(data: data, encoding: .utf8) {
        let crops = text.components(separatedBy: "\n").compactMap { CropRect.parse($0) }
        if !crops.isEmpty {
            saveCrops(crops)
            return crops
        }
    }
    return CropRect.defaultWindows
}

func saveCrops(_ crops: [CropRect]) {
    let obj: [String: Any] = ["windows": crops.map(\.dict)]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? data.write(to: URL(fileURLWithPath: configPath))
}

var allCrops = loadCrops()

let myIndex: Int = {
    guard let arg = CommandLine.arguments.dropFirst().first, let idx = Int(arg) else { return 0 }
    return idx
}()
let isMaster = myIndex == 0

guard myIndex < allCrops.count else {
    FileHandle.standardError.write(Data("dock-scrcpy: index \(myIndex) out of range (have \(allCrops.count) windows)\n".utf8))
    exit(1)
}

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
func waitForAdbDevice() async {
    var attempts = 0
    while !adbHasDevice() {
        masterRenderer?.broadcastPlaceholder("iphone.slash")
        attempts += 1
        if attempts > 10 {
            log("no adb device after 10 retries — giving up")
            dropDockTile()
            exit(1)
        }
        log("no adb device — restarting adb server, retrying in 10s... (\(attempts)/10)")
        runAdb(["kill-server"])
        runAdb(["start-server"])
        try? await Task.sleep(nanoseconds: 10_000_000_000)
    }
    log("adb device present")
}

// MARK: - Device brightness (master only)

// Dim the device screen while mirroring; restore on quit. The original value is
// persisted to a file because master restarts itself via exit(2) — a fresh
// incarnation must not mistake the already-dimmed level for the original.
let brightnessSaveFile = "/tmp/dock-scrcpy-brightness.saved"

func dimDeviceBrightness() {
    if !FileManager.default.fileExists(atPath: brightnessSaveFile) {
        var mode = runAdb(["shell", "settings", "get", "system", "screen_brightness_mode"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if Int(mode) == nil { mode = "0" }  // some ROMs return "null"
        let level = runAdb(["shell", "settings", "get", "system", "screen_brightness"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int(level) != nil else {
            log("cannot read device brightness — skip dimming")
            return
        }
        try? "\(mode) \(level)".write(toFile: brightnessSaveFile, atomically: true, encoding: .utf8)
    }
    runAdb(["shell", "settings", "put", "system", "screen_brightness_mode", "0"])  // disable auto
    runAdb(["shell", "settings", "put", "system", "screen_brightness", "1"])
    log("device brightness dimmed")
}

func restoreDeviceBrightness() {
    guard let s = try? String(contentsOfFile: brightnessSaveFile, encoding: .utf8) else { return }
    let parts = s.split(separator: " ").map(String.init)
    guard parts.count == 2 else { return }
    runAdb(["shell", "settings", "put", "system", "screen_brightness", parts[1]])
    runAdb(["shell", "settings", "put", "system", "screen_brightness_mode", parts[0]])
    try? FileManager.default.removeItem(atPath: brightnessSaveFile)
    log("device brightness restored (\(parts[1]), mode \(parts[0]))")
}

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
            kill(pid, SIGTERM)
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
    proc.arguments = ["-c",
        "./run x --crop=\(bbox.string) --turn-screen-off --window-borderless --window-title=\(scrcpyWindowTitle) --window-x=\(winX) --window-y=\(winY) --max-fps=\(Int(fps))"]
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

// Kill a process and all its descendants (bash → run → scrcpy chain).
// Killing only the Process handle orphans scrcpy if it hasn't been resolved
// from the captured window yet (early startup).
func killTree(_ pid: pid_t) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-P", "\(pid)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for child in out.split(separator: "\n").compactMap({ pid_t($0) }) {
        killTree(child)
    }
    kill(pid, SIGTERM)
}

func stopScrcpy() {
    scrcpyProc?.terminationHandler = nil  // avoid masterFail re-entry when we kill it ourselves
    if scrcpyWindowPID > 0 { kill(scrcpyWindowPID, SIGTERM) }
    if let proc = scrcpyProc, proc.isRunning {
        killTree(proc.processIdentifier)
    }
}

// Exit code 2 asks start.sh to restart us: a fresh process is the only reliable
// recovery from a poisoned SCK connection.
func masterFail(_ reason: String) -> Never {
    log("FATAL: \(reason) — exiting for restart")
    masterRenderer?.broadcastPlaceholder("iphone.slash")  // viewers show disconnect, not a frozen frame
    dropDockTile()
    stopScrcpy()
    exit(2)
}

// MARK: - Master: capture + render all crops

final class MasterRenderer: NSObject, SCStreamOutput {
    private let ctx = CIContext()
    private let crops: [CropRect]  // snapshot: bbox is fixed at launch, live edits must not desync
    private var iconCtxs: [CGContext] = []
    private var writers: [Int: FrameBuffer] = [:]
    private var loggedFirstFrame = false
    private(set) var frameCount = 0

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
        frameCount += 1
        let ci = CIImage(cvPixelBuffer: buf)
        if !loggedFirstFrame {
            loggedFirstFrame = true
            log("first frame: \(Int(ci.extent.width))x\(Int(ci.extent.height))")
        }
        for (i, crop) in crops.enumerated() {
            guard let cg = croppedIcon(ci, crop: crop, iconCtx: iconCtxs[i]) else { continue }
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

    private func croppedIcon(_ ci: CIImage, crop: CropRect, iconCtx: CGContext) -> CGImage? {
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
        ctx.render(img, toBitmap: dst, rowBytes: iconSize * 4,
                   bounds: CGRect(x: 0, y: 0, width: iconSize, height: iconSize),
                   format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return iconCtx.makeImage()
    }
}

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
func setScreenState(awake: Bool) {
    if !awake && !screenOffPaused && activeStream != nil {
        screenOffPaused = true
        let s = activeStream
        activeStream = nil
        Task { try? await s?.stopCapture() }
        masterRenderer?.broadcastPlaceholder("moon.fill")
        log("device screen off — capture paused")
    } else if awake && screenOffPaused {
        screenOffPaused = false
        log("device screen on — resuming capture")
        Task { @MainActor in await startCapture() }
    }
}

func startScreenStatePolling() {
    let t = Timer(timeInterval: 5, repeats: true) { _ in
        // Keepalive while paused: re-broadcast the placeholder so viewer seq
        // keeps moving and their 10s stale detector doesn't cry disconnect.
        if screenOffPaused { masterRenderer?.broadcastPlaceholder("moon.fill") }
        DispatchQueue.global().async {
            let out = runAdb(["shell", "dumpsys", "power"])
            guard out.contains("mWakefulness=") else { return }  // no device / unknown format
            let awake = out.contains("mWakefulness=Awake")
            DispatchQueue.main.async { setScreenState(awake: awake) }
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
    private var win2Widgets: [NSView] = []

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
        let pw: CGFloat = 340
        let ph: CGFloat = 280
        let content = NSView(frame: NSRect(x: 0, y: 0, width: pw, height: ph))

        let rowCount: CGFloat = ph - 32
        let row1Title: CGFloat = ph - 62
        let row1A: CGFloat = ph - 88
        let row1B: CGFloat = ph - 118
        let row2Title: CGFloat = ph - 150
        let row2A: CGFloat = ph - 176
        let row2B: CGFloat = ph - 206
        let rowBtn: CGFloat = 14

        let countLabel = NSTextField(labelWithString: "Windows:")
        countLabel.frame = NSRect(x: 20, y: rowCount, width: 70, height: 20)
        content.addSubview(countLabel)

        countControl = NSSegmentedControl(labels: ["1", "2"], trackingMode: .selectOne, target: self, action: #selector(countChanged))
        countControl.frame = NSRect(x: 100, y: rowCount, width: 100, height: 22)
        countControl.selectedSegment = min(allCrops.count, 2) - 1
        content.addSubview(countControl)

        fields = []
        win2Widgets = []

        for wi in 0..<2 {
            let crop = wi < allCrops.count ? allCrops[wi] : CropRect.defaultWindows[wi]
            let titleY = wi == 0 ? row1Title : row2Title
            let fieldRowA = wi == 0 ? row1A : row2A
            let fieldRowB = wi == 0 ? row1B : row2B

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
            if wi == 1 { win2Widgets = groupWidgets }
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
        let show2 = countControl.selectedSegment == 1
        win2Widgets.forEach { $0.isHidden = !show2 }
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
                // Invalid crop would give scrcpy a degenerate --crop and loop restarts.
                NSSound.beep()
                log("invalid crop for window \(i + 1): \(c.string) — not saved")
                return
            }
            crops.append(c)
        }
        allCrops = crops
        saveCrops(crops)
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

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        if isMaster { setupMenu() }
    }
    func applicationWillTerminate(_ n: Notification) {
        dropDockTile()
        if isMaster {
            stopScrcpy()
            restoreDeviceBrightness()  // clean quit: hand the screen back at original brightness
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit dock-scrcpy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
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
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSrc.setEventHandler { NSApp.terminate(nil) }
sigintSrc.resume()
let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSrc.setEventHandler { NSApp.terminate(nil) }
sigtermSrc.resume()

if isMaster {
    Task { @MainActor in
        masterRenderer?.broadcastPlaceholder("hourglass")
        await killStaleScrcpy()
        await waitForAdbDevice()
        dimDeviceBrightness()
        launchScrcpy()
        await startCapture()
        startScreenStatePolling()
    }
} else {
    DispatchQueue.main.async { viewerLoop() }
}

app.run()
