import SwiftUI
import AppKit
import QuartzCore

struct BottomPanels: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 5) {
            panel("AKTIVE CUER") {
                if model.engine.active.isEmpty {
                    Text("Ingenting spiller").foregroundColor(theme.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(model.engine.active) { ActiveRow(active: $0) }
                        }
                    }
                }
            }
            panel("HURTIGTASTER") {
                let hot = model.cues.filter { !$0.hotkey.isEmpty }
                if hot.isEmpty {
                    Text("Gi en cue en hurtigtast i panelet til høyre, så dukker den opp her. Hurtigtaster starter cuen uten å flytte GO-markøren.")
                        .foregroundColor(theme.faint).multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 132), spacing: 6, alignment: .leading)],
                                  alignment: .leading, spacing: 6) {
                            ForEach(hot) { HotButton(cue: $0) }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("UTGANG")
                PreviewView(root: model.output.previewRoot)
                    .frame(width: 300, height: 169)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .onTapGesture(count: 2) { model.output.toggle() }
                    .help("Dobbeltklikk for å vise/skjule utgangsvinduet")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(theme.panel)
        }
        .background(theme.bg)
    }

    private func panel<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title)
            content()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panel)
    }
}

struct ActiveRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme
    @ObservedObject var active: ActiveCue

    var body: some View {
        HStack(spacing: 0) {
            Text(active.cue.number).font(.system(size: 13, design: .monospaced)).foregroundColor(theme.muted).frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(active.cue.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(active.stateText).font(.system(size: 11)).foregroundColor(theme.muted)
                }
                ProgressBar(value: active.progress)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(active.elapsedText)
                Text(active.remainingText).foregroundColor(theme.wait)
            }
            .font(.system(size: 13, design: .monospaced))
            .frame(minWidth: 76, alignment: .trailing)
            .padding(.horizontal, 12)
            Button("■") { active.stop(fade: AppModel.fadeOut(of: active.cue)) }
                .buttonStyle(PanelButtonStyle())
                .help("Stopp (med cuens fade ut)")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 5).fill(theme.panel2))
    }
}

struct HotButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme
    @ObservedObject var cue: Cue

    var body: some View {
        Button { model.toggleHot(cue) } label: {
            VStack(alignment: .leading, spacing: 3) {
                RoundedRectangle(cornerRadius: 1.5).fill(theme.stripe(cue.color) ?? .clear).frame(height: 3)
                Text(cue.hotkey).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(theme.wait)
                Text(cue.displayName).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(width: 132, height: 62, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 5).fill(cue.isRunning ? theme.runningRow : theme.panel3))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(cue.isRunning ? theme.running : theme.line))
        }
        .buttonStyle(.plain)
    }
}

/// Viser forhåndsvisningslaget fra utgangen.
struct PreviewView: NSViewRepresentable {
    let root: CALayer

    func makeNSView(context: Context) -> NSView {
        let v = PreviewHostView()
        v.layer = root
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class PreviewHostView: NSView {
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.frame = bounds
            layer?.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
        }
    }
}
