import SwiftUI
import AppKit

/// Redigering av start- og sluttpunkt i en lyd- eller video-cue: bølgeform med dra-bare markører,
/// zoom og forhåndslytting gjennom lydpatchen.
struct WaveformEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var cue: Cue
    @ObservedObject var preview: AudioPreview
    var large = false

    @State private var data: WaveformData?
    @State private var status: String?
    @State private var viewStart = 0.0
    @State private var viewLength = 0.0
    @State private var cursor = 0.0
    @State private var playPos: Double?
    @State private var drag: DragKind?
    @State private var pinchBase: Double?
    @State private var loadedKey = ""

    private enum DragKind { case start, end, cursor }
    private static let ticker = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()
    static let minLength = 0.05

    // MARK: Avledede verdier

    private var length: Double {
        if let d = data?.duration, d > 0 { return d }
        if cue.mediaLength > 0 { return cue.mediaLength }
        return max(cue.endTime, cue.startTime) + 1
    }

    private var effectiveEnd: Double {
        let len = length
        return cue.endTime > 0 ? min(cue.endTime, len) : len
    }

    private var vis: (start: Double, length: Double) {
        let len = length
        let vl = viewLength <= 0 || viewLength > len ? len : viewLength
        return (min(max(0, viewStart), max(0, len - vl)), vl)
    }

    private var previewingThis: Bool { preview.isPlaying && preview.cue === cue }

    // MARK: Visning

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(infoText).font(.system(size: 11.5, design: .monospaced)).foregroundColor(theme.muted).lineLimit(1)
            GeometryReader { geo in
                canvas(size: geo.size)
            }
            .frame(height: large ? 360 : 120)
            .background(RoundedRectangle(cornerRadius: 3).fill(theme.panel3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 3))

            if vis.length < length - 1e-6 {
                Slider(value: Binding(get: { vis.start }, set: { viewStart = $0 }), in: 0...max(0.001, length - vis.length))
                    .controlSize(.mini)
            }

            HStack(spacing: 6) {
                Button("▶ Fra start") { play(from: cue.startTime) }.help("Lytt fra startpunktet (gjennom lydpatchen)")
                Button("▶ Fra markør") { play(from: cursor) }.help("Lytt fra den blå markøren. Klikk i bølgeformen for å flytte den, dobbeltklikk for å lytte derfra.")
                Button("▶ Slutten") { play(from: max(cue.startTime, effectiveEnd - 5)) }.help("Lytt til de siste 5 sekundene før sluttpunktet")
                Button("■ Stopp") { preview.stop() }.disabled(!previewingThis)
            }.buttonStyle(PanelButtonStyle())
            HStack(spacing: 6) {
                Button("Start = markør") { setStart(currentPoint) }.help("Sett startpunktet der markøren (eller lyttingen) er nå")
                Button("Slutt = markør") { setEnd(currentPoint) }.help("Sett sluttpunktet der markøren (eller lyttingen) er nå")
                Button("Nullstill") { cue.startTime = 0; cue.endTime = 0 }.help("Hele fila: start 0, slutt = filslutt")
                Button("−") { zoom(2, anchor: nil) }.help("Zoom ut (eller knip på styreflaten)")
                Button("+") { zoom(0.5, anchor: nil) }.help("Zoom inn (eller knip på styreflaten)")
                Button("Hele") { viewStart = 0; viewLength = 0 }.help("Vis hele fila")
                if !large {
                    Button("⤢ Stort vindu") { model.trimCue = cue; openWindow(id: "trim") }.help("Åpne et stort redigeringsvindu")
                }
            }.buttonStyle(PanelButtonStyle())
        }
        .onAppear { load() }
        .onChange(of: cue.filePath) { _ in viewStart = 0; viewLength = 0; load() }
        .onReceive(WaveformEditorView.ticker) { _ in tick() }
    }

    private var infoText: String {
        let end = effectiveEnd
        let endText = cue.endTime > 0 ? fmt(end) : fmt(end) + " (filslutt)"
        return "Start \(fmt(cue.startTime))   Slutt \(endText)   Lengde \(fmt(max(0, end - cue.startTime)))   Markør \(fmt(cursor))"
    }

    private func canvas(size: CGSize) -> some View {
        let v = vis
        let w = size.width, h = size.height
        func x(_ t: Double) -> Double { v.length <= 0 ? 0 : (t - v.start) / v.length * w }
        func t(_ px: Double) -> Double { v.start + px / max(1, w) * v.length }

        return Canvas { ctx, _ in
            let ruler = 16.0
            // Tidslinjal
            let step = WaveformEditorView.niceStep(v.length / max(1, w / 90))
            var tt = (v.start / step).rounded(.down) * step
            while tt <= v.start + v.length {
                let px = x(tt).rounded() + 0.5
                if px >= 0 {
                    var p = Path(); p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: ruler))
                    ctx.stroke(p, with: .color(theme.line), lineWidth: 1)
                    ctx.draw(Text(fmt(tt)).font(.system(size: 9.5)).foregroundColor(theme.muted), at: CGPoint(x: px + 3, y: 1), anchor: .topLeading)
                }
                tt += step
            }
            var rl = Path(); rl.move(to: CGPoint(x: 0, y: ruler + 0.5)); rl.addLine(to: CGPoint(x: w, y: ruler + 0.5))
            ctx.stroke(rl, with: .color(theme.line), lineWidth: 1)

            let top = ruler + 2, mid = (top + h) / 2, amp = (h - top) / 2 - 2

            // Bølgeform
            if let d = data, d.buckets > 0, d.duration > 0 {
                let bPerSec = Double(d.buckets) / d.duration
                var wave = Path()
                for px in 0..<Int(w) {
                    var b0 = Int((t(Double(px)) * bPerSec).rounded(.down))
                    var b1 = Int((t(Double(px + 1)) * bPerSec).rounded(.up))
                    if b1 <= 0 || b0 >= d.buckets { continue }
                    b0 = max(0, b0); b1 = min(d.buckets, max(b1, b0 + 1))
                    var mn: Float = 0, mx: Float = 0
                    for b in b0..<b1 { mn = min(mn, d.min[b]); mx = max(mx, d.max[b]) }
                    var y0 = mid - Double(min(1, mx)) * amp, y1 = mid - Double(max(-1, mn)) * amp
                    if y1 - y0 < 1 { y0 = mid - 0.5; y1 = mid + 0.5 }
                    wave.addRect(CGRect(x: Double(px), y: y0, width: 1, height: y1 - y0))
                }
                ctx.fill(wave, with: .color(theme.muted))
            } else if let s = status {
                ctx.draw(Text(s).font(.system(size: 11)).foregroundColor(theme.muted), at: CGPoint(x: 8, y: mid), anchor: .leading)
            }

            // Skygge utenfor start–slutt
            let xs = x(cue.startTime), xe = x(effectiveEnd)
            let shade = Color.black.opacity(0.55)
            if xs > 0 { ctx.fill(Path(CGRect(x: 0, y: top, width: min(w, xs), height: h - top)), with: .color(shade)) }
            if xe < w { ctx.fill(Path(CGRect(x: max(0, xe), y: top, width: w - max(0, xe), height: h - top)), with: .color(shade)) }

            // Fader
            if cue.fadeIn > 0 {
                var p = Path(); p.move(to: CGPoint(x: xs, y: h - 1)); p.addLine(to: CGPoint(x: x(min(effectiveEnd, cue.startTime + cue.fadeIn)), y: top + 1))
                ctx.stroke(p, with: .color(theme.wait), lineWidth: 1.5)
            }
            if cue.fadeOut > 0, !cue.loop, cue.type == .audio {
                var p = Path(); p.move(to: CGPoint(x: x(max(cue.startTime, effectiveEnd - cue.fadeOut)), y: top + 1)); p.addLine(to: CGPoint(x: xe, y: h - 1))
                ctx.stroke(p, with: .color(theme.wait), lineWidth: 1.5)
            }

            // Markør og avspillingsposisjon
            let xc = x(cursor).rounded() + 0.5
            var cp = Path(); cp.move(to: CGPoint(x: xc, y: top)); cp.addLine(to: CGPoint(x: xc, y: h))
            ctx.stroke(cp, with: .color(theme.playhead), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if let p = playPos {
                let xp = x(p)
                var pp = Path(); pp.move(to: CGPoint(x: xp, y: top)); pp.addLine(to: CGPoint(x: xp, y: h))
                ctx.stroke(pp, with: .color(theme.text), lineWidth: 1.5)
            }

            // Start- og sluttmarkør med «flagg»
            for (px, color, dir) in [(xs, theme.go, 1.0), (xe, theme.danger, -1.0)] {
                var l = Path(); l.move(to: CGPoint(x: px, y: top)); l.addLine(to: CGPoint(x: px, y: h))
                ctx.stroke(l, with: .color(color), lineWidth: 2)
                var f = Path()
                f.move(to: CGPoint(x: px, y: top)); f.addLine(to: CGPoint(x: px + 10 * dir, y: top)); f.addLine(to: CGPoint(x: px, y: top + 10)); f.closeSubpath()
                ctx.fill(f, with: .color(color))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if drag == nil {
                        let ds = abs(g.startLocation.x - startX(v, w)), de = abs(g.startLocation.x - endX(v, w))
                        drag = ds <= 7 && ds <= de ? .start : de <= 7 ? .end : .cursor
                    }
                    let tm = min(max(0, t(min(max(0, g.location.x), w))), length)
                    switch drag {
                    case .start: setStart(tm)
                    case .end: setEnd(tm)
                    default: cursor = tm
                    }
                }
                .onEnded { _ in drag = nil }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { g in
                cursor = min(max(0, t(g.location.x)), length)
                play(from: cursor)
            }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { m in
                    let base = pinchBase ?? vis.length
                    if pinchBase == nil { pinchBase = base }
                    setZoom(length: base / Double(max(0.05, m)), anchor: nil)
                }
                .onEnded { _ in pinchBase = nil }
        )
        .onContinuousHover { phase in
            if case .active(let p) = phase {
                let near = abs(p.x - startX(v, w)) <= 7 || abs(p.x - endX(v, w)) <= 7
                (near ? NSCursor.resizeLeftRight : NSCursor.iBeam).set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private func startX(_ v: (start: Double, length: Double), _ w: Double) -> Double { v.length <= 0 ? 0 : (cue.startTime - v.start) / v.length * w }
    private func endX(_ v: (start: Double, length: Double), _ w: Double) -> Double { v.length <= 0 ? 0 : (effectiveEnd - v.start) / v.length * w }

    // MARK: Handlinger

    private var currentPoint: Double { previewingThis ? (preview.position ?? cursor) : cursor }

    private func setStart(_ t: Double) {
        var v = max(0, t)
        let end = effectiveEnd
        if end > 0 { v = min(v, end - WaveformEditorView.minLength) }
        cue.startTime = (max(0, v) * 1000).rounded() / 1000
    }

    private func setEnd(_ t: Double) {
        let v = max(t, cue.startTime + WaveformEditorView.minLength)
        let len = length
        cue.endTime = len > 0 && v >= len - 0.005 ? 0 : (v * 1000).rounded() / 1000 // helt til slutten = «filslutt»
    }

    private func play(from t: Double) {
        guard model.audio.isRunning else {
            let a = NSAlert(); a.messageText = "Lydutgangen er ikke startet"; a.informativeText = "Sjekk Innstillinger → Lyd."; a.runModal()
            return
        }
        if !preview.play(cue, from: t, to: cue.endTime) {
            let a = NSAlert(); a.messageText = "Klarte ikke å spille av lyden i denne cuen."; a.runModal()
        }
    }

    private func zoom(_ factor: Double, anchor: Double?) { setZoom(length: vis.length * factor, anchor: anchor) }

    private func setZoom(length newLen: Double, anchor: Double?) {
        let len = length
        guard len > 0 else { return }
        let v = vis
        let a = anchor ?? (playPos ?? cursor)
        let frac = v.length > 0 ? min(max(0, (a - v.start) / v.length), 1) : 0.5
        let nl = min(max(newLen, min(len, 0.05)), len)
        viewStart = min(max(0, a - frac * nl), max(0, len - nl))
        viewLength = nl
    }

    private func tick() {
        let pos = previewingThis ? preview.position : nil
        if pos != playPos {
            playPos = pos
            if let p = pos {
                let v = vis
                if p > v.start + v.length || p < v.start { viewStart = max(0, p - v.length * 0.1) }
            }
        }
    }

    private func load() {
        let path = cue.filePath
        let isVideo = cue.type == .video
        let key = path + (isVideo ? "|v" : "|a")
        loadedKey = key
        data = nil
        cursor = cue.startTime
        guard !path.isEmpty else { status = "Ingen fil valgt"; return }
        status = "Leser bølgeform …"
        WaveformCache.shared.get(path: path, isVideo: isVideo) { d in
            guard loadedKey == key else { return }
            data = d
            status = d == nil ? (isVideo ? "Videoen har ikke noe lydspor – markørene virker likevel" : "Kunne ikke lese fila") : nil
        }
    }

    private func fmt(_ s: Double) -> String {
        let v = max(0, s)
        let m = Int(v / 60)
        return String(format: "%d:%05.2f", m, v - Double(m) * 60)
    }

    static func niceStep(_ raw: Double) -> Double {
        for s in [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600] where s >= raw { return s }
        return 3600
    }
}

/// Eget stort vindu for å redigere start og slutt.
struct TrimWindowView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme

    var body: some View {
        Group {
            if let cue = model.trimCue {
                TrimWindowContent(cue: cue, preview: model.engine.preview)
            } else {
                Text("Velg en lyd- eller video-cue og trykk «Stort vindu».").foregroundColor(theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(theme.bg)
        .onDisappear { if model.engine.preview.cue === model.trimCue { model.engine.preview.stop() } }
    }
}

private struct TrimWindowContent: View {
    @ObservedObject var cue: Cue
    @ObservedObject var preview: AudioPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(cue.number.isEmpty ? "" : cue.number + " · ")\(cue.displayName)").font(.system(size: 15, weight: .semibold))
            WaveformEditorView(cue: cue, preview: preview, large: true).id(cue.id)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    FieldLabel("Start (s)"); NumberInput(value: $cue.startTime, range: 0...86400)
                }.frame(width: 200)
                VStack(alignment: .leading, spacing: 0) {
                    FieldLabel("Slutt (s, 0 = filslutt)"); NumberInput(value: $cue.endTime, range: 0...86400)
                }.frame(width: 200)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
