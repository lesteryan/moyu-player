import AppKit
import AVFoundation

// Usage: dockvideo <video file>
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test.mp4"
guard FileManager.default.fileExists(atPath: path) else {
    FileHandle.standardError.write(Data("dockvideo: file not found: \(path)\n".utf8))
    exit(1)
}
let url = URL(fileURLWithPath: path)

let app = NSApplication.shared
app.setActivationPolicy(.regular) // ensure Dock icon

let player = AVPlayer(url: url)
guard let item = player.currentItem else {
    FileHandle.standardError.write(Data("dockvideo: cannot open \(path)\n".utf8))
    exit(1)
}
let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
])
item.add(output)
player.actionAtItemEnd = .none
// loop
NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                       object: item, queue: .main) { _ in
    player.seek(to: .zero)
}
player.play()

let ciContext = CIContext()

Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
    let t = output.itemTime(forHostTime: CACurrentMediaTime())
    guard output.hasNewPixelBuffer(forItemTime: t),
          let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
    let ci = CIImage(cvPixelBuffer: pb)
    guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
    let img = NSImage(cgImage: cg, size: NSSize(width: 128, height: 128))
    NSApp.applicationIconImage = img
}

app.run()
