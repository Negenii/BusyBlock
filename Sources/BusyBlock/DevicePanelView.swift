import AppKit
import Combine
import BusyBlockCore

/// Latest front-panel frame from the bar, for the settings window.
@MainActor
final class LiveFrames: ObservableObject {
    static let shared = LiveFrames()
    @Published var frame: BarFrame?
    @Published var connected = false
}

/// The BUSY Bar render with the live 72×16 panel drawn over its glass, in the
/// same style as the browser extension (rounded LEDs, dark ones transparent).
final class DevicePanelView: NSView {
    var frame72: BarFrame? { didSet { needsDisplay = true } }
    var dimmed = false { didSet { needsDisplay = true } }
    private let device: NSImage? = {
        if let url = Bundle.main.url(forResource: "busybar-device", withExtension: "png"), let img = NSImage(contentsOf: url) { return img }
        // `swift run` has no bundle resources: fall back to the repo copy.
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("extension/brand/busybar-device.png")
        return NSImage(contentsOf: repo)
    }()

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: bounds.width * 248 / 768) }
    override func layout() { super.layout(); invalidateIntrinsicContentSize() }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = w * 248 / 768
        let imgRect = NSRect(x: 0, y: bounds.height - h, width: w, height: h)
        device?.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.45 : 1)
        // Panel geometry from the official mirror: 3.1% / 24.7% / 93.5% / 64.3%.
        let panel = NSRect(x: imgRect.minX + w * 0.031, y: imgRect.maxY - h * 0.247 - h * 0.643, width: w * 0.935, height: h * 0.643)
        guard let f = frame72, f.width > 0, f.height > 0 else { return }
        let cell = panel.width / CGFloat(f.width)
        let size = cell * 0.85, inset = (cell - size) / 2, radius = size * 0.35
        f.rgb.withUnsafeBytes { buf in
            let p = buf.bindMemory(to: UInt8.self)
            for y in 0..<f.height {
                for x in 0..<f.width {
                    let i = (y * f.width + x) * 3
                    guard i + 2 < p.count else { continue }
                    let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                    if r + g + b < 30 { continue }
                    NSColor(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: dimmed ? 0.5 : 1).setFill()
                    let rect = NSRect(x: panel.minX + CGFloat(x) * cell + inset,
                                      y: panel.maxY - CGFloat(y + 1) * cell + inset,
                                      width: size, height: size)
                    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                }
            }
        }
    }
}
