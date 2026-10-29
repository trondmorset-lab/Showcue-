import AppKit
import AVFoundation
import QuartzCore
import PDFKit

/// To like lag: ett i utgangsvinduet (projektor) og ett i forhåndsvisningen i hovedvinduet.
final class LayerPair {
    let output: CALayer
    let preview: CALayer

    init(output: CALayer, preview: CALayer) {
        self.output = output
        self.preview = preview
    }

    func setOpacity(_ value: Float, duration: Double) {
        for l in [output, preview] {
            CATransaction.begin()
            if duration <= 0 {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(duration)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            }
            l.opacity = value
            CATransaction.commit()
        }
    }

    /// Nåværende synlighet (midt i en fade).
    var currentOpacity: Float { output.presentation()?.opacity ?? output.opacity }

    func remove() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        output.removeFromSuperlayer()
        preview.removeFromSuperlayer()
        CATransaction.commit()
    }
}

/// Utgangen for video, bilde og PDF: et vindu på valgt skjerm (eller et vanlig vindu) + forhåndsvisning.
final class OutputCompositor: NSObject, ObservableObject, NSWindowDelegate {
    let previewRoot = CALayer()
    private let outputRoot = CALayer()
    private var window: NSWindow?
    private var screenIndex = -1
    @Published private(set) var isVisible = false

    override init() {
        super.init()
        for r in [previewRoot, outputRoot] {
            r.backgroundColor = NSColor.black.cgColor
            r.masksToBounds = true
            r.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        }
    }

    static func screenNames() -> [String] {
        NSScreen.screens.enumerated().map { i, s in
            let f = s.frame
            return "Skjerm \(i + 1): \(s.localizedName) – \(Int(f.width))×\(Int(f.height))" + (i == 0 ? " (hovedskjerm)" : "")
        }
    }

    func configure(screen: Int) {
        screenIndex = screen
        if let w = window {
            let wasVisible = w.isVisible
            w.orderOut(nil)
            window = nil
            if wasVisible { ensureVisible() }
        }
    }

    func ensureVisible() {
        if window == nil { window = makeWindow() }
        window?.orderFront(nil)
        isVisible = true
    }

    func toggle() {
        if let w = window, w.isVisible { w.orderOut(nil); isVisible = false } else { ensureVisible() }
    }

    private func makeWindow() -> NSWindow {
        let screens = NSScreen.screens
        let full = screenIndex >= 0 && screenIndex < screens.count
        let rect = full ? screens[screenIndex].frame : NSRect(x: 200, y: 200, width: 960, height: 540)
        let w = NSWindow(contentRect: rect,
                         styleMask: full ? [.borderless] : [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "ShowCue – utgang"
        w.backgroundColor = .black
        w.delegate = self
        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        view.layer = outputRoot
        view.wantsLayer = true
        outputRoot.frame = view.bounds
        w.contentView = view
        if full {
            w.setFrame(screens[screenIndex].frame, display: true)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.hidesOnDeactivate = false
        }
        return w
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil) // lukking skjuler bare vinduet
        isVisible = false
        return false
    }

    // MARK: Lag

    static func gravity(_ s: VisualStretch) -> CALayerContentsGravity {
        switch s {
        case .uniform: return .resizeAspect
        case .uniformToFill: return .resizeAspectFill
        case .fill: return .resize
        case .none: return .center
        }
    }

    static func videoGravity(_ s: VisualStretch) -> AVLayerVideoGravity {
        switch s {
        case .uniform, .none: return .resizeAspect
        case .uniformToFill: return .resizeAspectFill
        case .fill: return .resize
        }
    }

    private func attach(_ make: () -> CALayer) -> LayerPair {
        ensureVisible()
        let o = make(), p = make()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, root) in [(o, outputRoot), (p, previewRoot)] {
            l.frame = root.bounds
            l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            l.opacity = 0
            root.addSublayer(l)
        }
        CATransaction.commit()
        return LayerPair(output: o, preview: p)
    }

    func addImage(_ image: CGImage?, stretch: VisualStretch) -> LayerPair {
        attach {
            let l = CALayer()
            l.contents = image
            l.contentsGravity = OutputCompositor.gravity(stretch)
            l.minificationFilter = .trilinear
            l.magnificationFilter = .linear
            return l
        }
    }

    func addVideo(_ player: AVPlayer, stretch: VisualStretch) -> LayerPair {
        attach {
            let l = AVPlayerLayer(player: player)
            l.videoGravity = OutputCompositor.videoGravity(stretch)
            l.backgroundColor = NSColor.clear.cgColor
            return l
        }
    }
}

/// Laster og cacher bilder og PDF-sider, så GO blir umiddelbar.
final class MediaCache {
    static let shared = MediaCache()
    private var cache: [String: CGImage] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "showcue.media", qos: .userInitiated)
    var pdfWidth: CGFloat = 1920

    private func key(_ path: String, _ page: Int) -> String { "\(path)#\(page)" }

    func cached(path: String, page: Int = 0) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[key(path, page)]
    }

    /// Henter bildet (fra cache, ellers lastes det synkront).
    func image(path: String, page: Int = 0) -> CGImage? {
        if let c = cached(path: path, page: page) { return c }
        let img = page > 0 ? MediaCache.renderPdf(path: path, page: page, width: pdfWidth) : MediaCache.loadImage(path)
        if let img { lock.lock(); cache[key(path, page)] = img; lock.unlock() }
        return img
    }

    func preload(_ cues: [Cue]) {
        let items = cues.compactMap { c -> (String, Int)? in
            if c.type == .image { return (c.filePath, 0) }
            if c.type == .pdf { return (c.filePath, c.page) }
            return nil
        }.filter { FileManager.default.fileExists(atPath: $0.0) }
        queue.async { [weak self] in items.forEach { _ = self?.image(path: $0.0, page: $0.1) } }
    }

    func clear() { lock.lock(); cache.removeAll(); lock.unlock() }

    static func loadImage(_ path: String) -> CGImage? {
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        var rect = NSRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func pdfPageCount(_ path: String) -> Int {
        PDFDocument(url: URL(fileURLWithPath: path))?.pageCount ?? 0
    }

    static func renderPdf(path: String, page: Int, width: CGFloat) -> CGImage? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), page >= 1, page <= doc.pageCount,
              let p = doc.page(at: page - 1) else { return nil }
        let bounds = p.bounds(for: .mediaBox)
        guard bounds.width > 0 else { return nil }
        let scale = width / bounds.width
        let size = CGSize(width: width, height: (bounds.height * scale).rounded())
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        p.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
