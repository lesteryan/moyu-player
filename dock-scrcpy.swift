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

    func write(pixels: UnsafeRawPointer) {
        memcpy(ptr + shmHeaderSize, pixels, shmPixelBytes)
        let next = seq &+ 1
        ptr.storeBytes(of: next, toByteOffset: 0, as: UInt64.self)
    }

    func read(into buf: UnsafeMutableRawPointer) -> UInt64 {
        memcpy(buf, ptr + shmHeaderSize, shmPixelBytes)
        return seq
    }
}

func makeIconContext() -> CGContext {
    CGContext(data: nil, width: iconSize, height: iconSize, bitsPerComponent: 8,
              bytesPerRow: iconSize * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
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
        "./run x --crop=\(bbox.string) --window-borderless --window-title=\(scrcpyWindowTitle) --window-x=\(winX) --window-y=\(winY) --max-fps=\(Int(fps))"]
    var env = ProcessInfo.processInfo.environment
    env["SDL_MAC_BACKGROUND_APP"] = "1"  // accessory app: no Dock icon for scrcpy
    proc.environment = env
    proc.terminationHandler = { _ in
        log("scrcpy exited")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    do {
        try proc.run()
    } catch {
        log("ERROR: failed to launch scrcpy: \(error)")
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
    if scrcpyWindowPID > 0 { kill(scrcpyWindowPID, SIGTERM) }
    if let proc = scrcpyProc, proc.isRunning {
        proc.terminationHandler = nil
        killTree(proc.processIdentifier)
    }
}

// Exit code 2 asks start.sh to restart us: a fresh process is the only reliable
// recovery from a poisoned SCK connection.
func masterFail(_ reason: String) -> Never {
    log("FATAL: \(reason) — exiting for restart")
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

        // Square-crop, then downscale into the 128x128 icon context
        let w = cropped.extent.width, h = cropped.extent.height
        if w != h {
            let side = min(w, h)
            let ox = cropped.extent.origin.x + (w - side) / 2
            let oy = cropped.extent.origin.y + (h - side) / 2
            cropped = cropped.cropped(to: CGRect(x: ox, y: oy, width: side, height: side))
        }
        guard let full = ctx.createCGImage(cropped, from: cropped.extent) else { return nil }
        iconCtx.draw(full, in: CGRect(x: 0, y: 0, width: iconSize, height: iconSize))
        return iconCtx.makeImage()
    }
}

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

func scheduleRetry() {
    guard !retryPending else { return }
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
        try stream.addStreamOutput(masterRenderer!, type: .screen, sampleHandlerQueue: .global())
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

// MARK: - Viewer: poll shared memory

func viewerLoop() {
    var fb: FrameBuffer?
    var lastSeq: UInt64 = 0
    var staleTicks = 0
    let pixels = UnsafeMutableRawPointer.allocate(byteCount: shmPixelBytes, alignment: 8)

    Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { _ in
        if fb == nil {
            fb = FrameBuffer(index: myIndex, create: false)
            if fb == nil { return }  // master not up yet
            log("attached to \(shmPath(myIndex))")
        }
        guard let f = fb else { return }
        let seq = f.read(into: pixels)
        if seq == lastSeq {
            staleTicks += 1
            if staleTicks == Int(fps) * 30 { log("no new frames for 30s (master gone?)") }
            return
        }
        lastSeq = seq
        staleTicks = 0
        let ctx = CGContext(data: pixels, width: iconSize, height: iconSize, bitsPerComponent: 8,
                            bytesPerRow: iconSize * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = ctx?.makeImage() else { return }
        NSApp.applicationIconImage = NSImage(cgImage: cg, size: NSSize(width: iconSize, height: iconSize))
    }
}

// MARK: - Settings (master only)

class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
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

            let labels = ["W:", "H:", "X:", "Y:"]
            let values = [crop.w, crop.h, crop.x, crop.y]
            var rowFields: [NSTextField] = []
            var groupWidgets: [NSView] = [title]

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

    @objc func applySettings() {
        let count = countControl.selectedSegment + 1
        var crops: [CropRect] = []
        for i in 0..<count {
            let f = fields[i]
            crops.append(CropRect(w: f[0].integerValue, h: f[1].integerValue,
                                  x: f[2].integerValue, y: f[3].integerValue))
        }
        allCrops = crops
        saveCrops(crops)
        log("settings saved: \(crops.map(\.string)) — restart to apply")
        window?.close()
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
        if isMaster { stopScrcpy() }
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
        await killStaleScrcpy()
        launchScrcpy()
        await startCapture()
    }
} else {
    DispatchQueue.main.async { viewerLoop() }
}

app.run()
