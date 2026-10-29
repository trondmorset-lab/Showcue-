import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ToolbarRow()
            HSplitView {
                CueListView()
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                InspectorView()
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 480, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(theme.bg).frame(height: 5)
            BottomPanels()
                .frame(height: 230)
            StatusBar()
        }
        .background(theme.bg)
        .navigationTitle(model.windowTitle)
    }
}

// MARK: - Toppfelt med GO

struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 18) {
            Button(action: model.go) {
                Text("GO").font(.system(size: 30, weight: .bold)).foregroundColor(theme.goText)
                    .frame(width: 170, height: 92)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.go))
            }
            .buttonStyle(.plain)
            .help("Mellomrom")

            NextCueInfo(cue: model.playhead)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                ClockText(live: model.live)
                let n = model.engine.active.count
                Text(n == 0 ? " " : "\(n) aktive").font(.system(size: 12)).foregroundColor(theme.muted)
            }
            MeterView(live: model.live)
                .frame(width: 26, height: 84)
                .help("Utgangsnivå, utgang 1 og 2 (−60 til 0 dBFS)")
            Button(action: model.panic) {
                VStack(spacing: 2) {
                    Text("STOPP ALT").font(.system(size: 17, weight: .semibold))
                    Text("Esc").font(.system(size: 11)).opacity(0.8)
                }
                .foregroundColor(.white)
                .frame(width: 130, height: 92)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.danger))
            }
            .buttonStyle(.plain)
            .help("Stopp alt med kort fade. Trykk to ganger for umiddelbar stopp.")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(theme.panel)
        .overlay(Rectangle().fill(theme.line).frame(height: 1), alignment: .bottom)
    }
}

struct NextCueInfo: View {
    @Environment(\.theme) var theme
    let cue: Cue?

    var body: some View {
        if let c = cue {
            NextCueContent(cue: c)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader("NESTE CUE")
                Text("— slutt på lista —").font(.system(size: 26, weight: .semibold)).foregroundColor(theme.muted)
            }
        }
    }
}

private struct NextCueContent: View {
    @Environment(\.theme) var theme
    @ObservedObject var cue: Cue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader("NESTE CUE")
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(cue.number).font(.system(size: 26, weight: .bold, design: .monospaced)).foregroundColor(theme.playhead)
                Text(cue.displayName).font(.system(size: 26, weight: .semibold)).lineLimit(1)
            }
            Text(cue.summary).font(.system(size: 13)).foregroundColor(theme.muted).lineLimit(1)
            if !cue.notes.isEmpty {
                Text(cue.notes).font(.system(size: 13)).foregroundColor(theme.wait).lineLimit(1)
            }
        }
    }
}

struct ClockText: View {
    @ObservedObject var live: LiveState
    var body: some View { Text(live.clockText.isEmpty ? "--:--:--" : live.clockText).font(.system(size: 30, design: .monospaced)) }
}

struct MeterView: View {
    @ObservedObject var live: LiveState
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 3) {
            bar(live.meterL)
            bar(live.meterR)
        }
    }

    private func bar(_ v: Float) -> some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(theme.panel3)
                LinearGradient(stops: [.init(color: Color(hex: 0x25B566), location: 0), .init(color: Color(hex: 0x25B566), location: 0.75),
                                       .init(color: Color(hex: 0xE3A33A), location: 0.86), .init(color: Color(hex: 0xE5484D), location: 0.97)],
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: g.size.height)
                    .mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * CGFloat(v)) }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
    }
}

// MARK: - Verktøylinje

struct ToolbarRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme
    @Environment(\.openWindow) var openWindow

    var body: some View {
        HStack(spacing: 0) {
            Group {
                Button("Ny") { model.newShow() }
                Button("Åpne") { model.openDialog() }
                Button("Lagre") { model.save(as: false) }
                Button("Lagre som") { model.save(as: true) }
            }
            divider
            Text("Legg til:").font(.system(size: 12)).foregroundColor(theme.muted).padding(.horizontal, 4).fixedSize()
            Group {
                Button("♪ Lyd") { model.add(.audio) }.help("⌘1")
                Button("▶ Video") { model.add(.video) }.help("⌘2")
                Button("▣ Bilde") { model.add(.image) }.help("⌘3")
                Button("▤ PDF") { model.add(.pdf) }.help("⌘4")
                Button("◢ Fade") { model.add(.fade) }.help("⌘5 – fader valgt cue")
                Button("■ Stopp") { model.add(.stop) }.help("⌘6")
                Button("⇢ OSC") { model.add(.osc) }.help("⌘7")
                Button("♫ MIDI") { model.add(.midi) }.help("⌘8")
            }
            divider
            Group {
                Button("Dupliser") { model.duplicateSelected() }.help("⌘D")
                Button("Slett") { model.deleteSelected() }.help("⌫")
                Button("↑") { model.moveSelected(-1) }.help("Flytt opp (⌘↑)")
                Button("↓") { model.moveSelected(1) }.help("Flytt ned (⌘↓)")
                Button("Nummerer") { model.renumber() }.help("Gi alle cuer fortløpende nummer")
            }
            Spacer(minLength: 8)
            Button("Lydpatch") { openWindow(id: "patch") }.help("Utganger og kanaler på lydkortet (Dante, flerkanals)")
            Button("Utgang") { model.output.toggle() }.help("Vis/skjul utgangsvinduet (video, bilde, PDF)")
            SettingsButton()
            Button(themeGlyph) { model.settings.theme = model.settings.theme.next }
                .font(.system(size: 15))
                .help("Bytt tema: mørk → lys → natt")
        }
        .buttonStyle(ToolButtonStyle())
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(theme.panel)
        .overlay(Rectangle().fill(theme.line).frame(height: 1), alignment: .bottom)
    }

    private var themeGlyph: String {
        switch model.settings.theme {
        case .dark: return "☀︎"
        case .light: return "☾"
        case .night: return "◐"
        }
    }

    private var divider: some View {
        Rectangle().fill(theme.line).frame(width: 1, height: 20).padding(.horizontal, 8)
    }
}

/// «Innstillinger» – SettingsLink på macOS 14+, ellers menykommandoen.
struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Text("Innstillinger") }
        } else {
            Button("Innstillinger") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}

// MARK: - Statuslinje

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme

    var body: some View {
        HStack {
            Text(model.statusText).foregroundColor(theme.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 16)
            Text(model.remoteStatus).foregroundColor(theme.faint).lineLimit(1)
                .help("Mellomrom = GO · Esc = stopp alt · ↑↓ = flytt markør · dra filer inn i lista")
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(theme.panel)
        .overlay(Rectangle().fill(theme.line).frame(height: 1), alignment: .top)
    }
}
