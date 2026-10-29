import SwiftUI
import UniformTypeIdentifiers

/// Kolonnebredder (samme som Windows-versjonen).
private enum Col {
    static let status: CGFloat = 30, number: CGFloat = 60, type: CGFloat = 66
    static let preWait: CGFloat = 76, length: CGFloat = 76, cont: CGFloat = 28, trigger: CGFloat = 104
}

struct CueListView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.cues.enumerated()), id: \.element.id) { i, cue in
                            CueRow(cue: cue, index: i, selected: model.selection.contains(cue.id))
                                .id(cue.id)
                                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                    loadURLs(providers) { model.addFiles($0, at: i + 1) }
                                    return true
                                }
                        }
                    }
                }
                .onChange(of: model.selection) { sel in
                    if let c = model.playhead, sel.count == 1 { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(c.id) } }
                }
            }
            .overlay {
                if model.cues.isEmpty {
                    VStack(spacing: 6) {
                        Text("Dra lyd-, video-, bilde- eller PDF-filer hit").font(.system(size: 18)).foregroundColor(theme.muted)
                        Text("eller bruk «Legg til» i verktøylinja").font(.system(size: 13)).foregroundColor(theme.faint)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.playhead, lineWidth: dropTargeted ? 2 : 0))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadURLs(providers) { model.addFiles($0) }
                return true
            }
        }
        .background(theme.panel)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("").frame(width: Col.status)
            h("NR").frame(width: Col.number, alignment: .leading)
            h("TYPE").frame(width: Col.type, alignment: .leading)
            h("NAVN").frame(maxWidth: .infinity, alignment: .leading)
            h("MÅL / FIL").frame(maxWidth: .infinity, alignment: .leading)
            h("PRE-WAIT").frame(width: Col.preWait, alignment: .leading)
            h("LENGDE").frame(width: Col.length, alignment: .leading)
            Text("").frame(width: Col.cont)
            h("TRIGGER").frame(width: Col.trigger, alignment: .leading)
        }
        .padding(.leading, 3)
        .padding(.vertical, 7)
        .overlay(Rectangle().fill(theme.line).frame(height: 1), alignment: .bottom)
    }

    private func h(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.muted).padding(.horizontal, 8)
    }

    private func loadURLs(_ providers: [NSItemProvider], then: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                if let u = url { lock.lock(); urls.append(u); lock.unlock() }
            }
        }
        group.notify(queue: .main) { then(urls) }
    }
}

struct CueRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme
    @ObservedObject var cue: Cue
    let index: Int
    let selected: Bool

    private var background: Color {
        if selected { return theme.playheadRow }
        if cue.isRunning { return theme.runningRow }
        if let t = theme.tint(cue.color) { return t }
        return index % 2 == 1 ? theme.rowAlt : theme.panel
    }

    private var stripe: Color {
        if selected { return theme.playhead }
        return theme.stripe(cue.color) ?? .clear
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if cue.isRunning { Circle().fill(theme.running).frame(width: 9, height: 9) }
                if cue.isPreWaiting { Circle().fill(theme.wait).frame(width: 9, height: 9) }
                if let e = cue.error {
                    Text("!").font(.system(size: 15, weight: .bold)).foregroundColor(theme.danger).help(e)
                }
            }
            .frame(width: Col.status)
            Text(cue.number).font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8).frame(width: Col.number, alignment: .leading)
            HStack(spacing: 2) {
                Text(cue.typeIcon).frame(width: 16)
                Text(cue.typeName).font(.system(size: 12))
            }
            .foregroundColor(theme.muted).padding(.horizontal, 8).frame(width: Col.type, alignment: .leading)
            Text(cue.displayName).lineLimit(1).padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    if cue.isRunning {
                        ProgressBar(value: cue.progress, height: 3).padding(.horizontal, 8).offset(y: 9)
                    }
                }
            Text(cue.summary).foregroundColor(theme.muted).lineLimit(1).padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(cue.preWaitText).font(.system(size: 13, design: .monospaced)).foregroundColor(theme.wait)
                .padding(.horizontal, 8).frame(width: Col.preWait, alignment: .leading)
            Text(cue.durationText).font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 8).frame(width: Col.length, alignment: .leading)
            Text(cue.continueMode.glyph).font(.system(size: 16)).foregroundColor(theme.playhead)
                .frame(width: Col.cont)
            Text(cue.triggerText).font(.system(size: 12.5, design: .monospaced)).foregroundColor(theme.wait).lineLimit(1)
                .padding(.horizontal, 8).frame(width: Col.trigger, alignment: .leading)
        }
        .font(.system(size: 13.5))
        .frame(height: 34)
        .background(background)
        .overlay(Rectangle().fill(stripe).frame(width: 3), alignment: .leading)
        .overlay(Rectangle().fill(theme.gridLine).frame(height: 1), alignment: .bottom)
        .opacity(cue.disabled ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
            let flags = NSEvent.modifierFlags
            model.click(cue, command: flags.contains(.command), shift: flags.contains(.shift))
            // Dobbeltklikk: test cuen uten å flytte GO-markøren.
            if NSApp.currentEvent?.clickCount == 2 { model.fire(cue) }
        }
        .contextMenu {
            Button("Test (spill nå)") { model.fire(cue) }
            Button("Stopp") { model.stop(cue) }
            Divider()
            Menu("Farge") {
                ForEach(CueColor.allCases, id: \.self) { c in Button(c.label) { cue.color = c } }
            }
            Button(cue.disabled ? "Aktiver" : "Deaktiver") { cue.disabled.toggle() }
            Button("Dupliser") { model.select(cue); model.duplicateSelected() }
        }
    }
}

struct ProgressBar: View {
    @Environment(\.theme) var theme
    let value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.panel3)
                Capsule().fill(theme.running).frame(width: g.size.width * CGFloat(min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}
