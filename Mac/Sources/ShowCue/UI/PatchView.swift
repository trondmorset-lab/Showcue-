import SwiftUI

/// Lydpatch: rader = utganger (busser) som cuene sender til, kolonner = kanaler på lydkortet.
/// Kryss av for å sende en utgang til en kanal. Endringer høres med en gang.
struct PatchView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var audio: AudioEngine
    @Environment(\.theme) var theme

    private let rowH: CGFloat = 30
    private let colW: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(audio.isRunning ? audio.status : "Lydutgangen er ikke startet. Velg lydkort under Innstillinger.")
                .foregroundColor(audio.isRunning ? theme.text : theme.danger)
                .padding(.bottom, 6)
            Text("Lyd-cuer sender til utganger (rader). Kryss av for hvilke kanaler på lydkortet hver utgang skal ut på. «Test» spiller rosa støy (−18 dBFS) på utgangen – fin for linjesjekk mot Dante/PA. Patchen lagres på denne maskinen, ikke i showfila.")
                .font(.system(size: 11.5)).foregroundColor(theme.faint).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("+ Utgang") {
                    let n = model.settings.buses.count + 1
                    model.settings.buses.append(PatchBus(name: "Utgang \(n)", channels: n <= audio.deviceChannels ? [n] : []))
                    model.applyPatch()
                }
                Button("− Fjern siste") {
                    guard model.settings.buses.count > 1 else { return }
                    audio.setTestTone(bus: model.settings.buses.count - 1, on: false)
                    model.settings.buses.removeLast()
                    model.applyPatch()
                }
                Button("1:1") {
                    for i in model.settings.buses.indices { model.settings.buses[i].channels = i < audio.deviceChannels ? [i + 1] : [] }
                    model.applyPatch()
                }
                Button("Nullstill krysspunkter") {
                    for i in model.settings.buses.indices { model.settings.buses[i].channels = [] }
                    model.applyPatch()
                }
                Button("Stopp testtoner") { audio.stopAllTestTones() }
            }
            .buttonStyle(PanelButtonStyle())
            .padding(.vertical, 10)

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    leftTable
                    ScrollView(.horizontal) { channelGrid }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minWidth: 640, minHeight: 320, alignment: .topLeading)
        .background(theme.panel)
        .onDisappear { audio.stopAllTestTones() }
    }

    // MARK: Venstre del: navn, nivå, test, måler

    private var leftTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                header("#").frame(width: 34, alignment: .leading)
                header("UTGANG").frame(width: 170, alignment: .leading)
                header("NIVÅ dB").frame(width: 64, alignment: .leading)
                header("TEST").frame(width: 56, alignment: .leading)
                header("NIVÅ").frame(width: 80, alignment: .leading)
            }
            .frame(height: 44, alignment: .bottom)
            ForEach(model.settings.buses.indices, id: \.self) { i in
                HStack(spacing: 0) {
                    Text("\(i + 1)").foregroundColor(theme.muted).frame(width: 34, alignment: .leading)
                    TextInput(Binding(get: { model.settings.buses[safe: i]?.name ?? "" },
                                      set: { v in if i < model.settings.buses.count { model.settings.buses[i].name = v; model.applyPatch() } }))
                        .padding(.trailing, 6).frame(width: 170)
                    NumberInput(value: Binding(get: { model.settings.buses[safe: i]?.gainDb ?? 0 },
                                               set: { v in if i < model.settings.buses.count { model.settings.buses[i].gainDb = v; model.applyPatch() } }),
                                range: -60...12)
                        .padding(.trailing, 6).frame(width: 64)
                    Button("Test") { audio.setTestTone(bus: i, on: !audio.testTones.contains(i)) }
                        .buttonStyle(PanelButtonStyle(fill: audio.testTones.contains(i) ? Color(hex: 0xE3A33A) : nil,
                                                      foreground: audio.testTones.contains(i) ? Color(hex: 0x1A1200) : nil))
                        .padding(.trailing, 6).frame(width: 56)
                    BusMeter(bus: i).frame(width: 74, height: 8).padding(.trailing, 6)
                }
                .frame(height: rowH)
            }
            Text("Kanalnivå på lydkortet").font(.system(size: 11.5)).foregroundColor(theme.muted)
                .padding(.leading, 34).frame(height: rowH)
        }
    }

    // MARK: Høyre del: krysspunkter per kanal

    private var channelGrid: some View {
        let D = audio.deviceChannels
        let names = audio.channelNames
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<D, id: \.self) { c in
                    header("\(c + 1)").frame(width: colW).help(c < names.count ? "Kanal \(c + 1): \(names[c])" : "Kanal \(c + 1)")
                }
            }
            .frame(height: 44, alignment: .bottom)
            ForEach(model.settings.buses.indices, id: \.self) { i in
                HStack(spacing: 0) {
                    ForEach(0..<D, id: \.self) { c in
                        Toggle("", isOn: Binding(
                            get: { model.settings.buses[safe: i]?.channels.contains(c + 1) ?? false },
                            set: { on in
                                guard i < model.settings.buses.count else { return }
                                var ch = model.settings.buses[i].channels.filter { $0 != c + 1 }
                                if on { ch.append(c + 1); ch.sort() }
                                model.settings.buses[i].channels = ch
                                model.applyPatch()
                            }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .frame(width: colW, height: rowH)
                            .background(i % 2 == 1 ? theme.panel2 : Color.clear)
                            .overlay(Rectangle().fill((c + 1) % 8 == 0 ? theme.line : .clear).frame(width: 1), alignment: .trailing)
                            .help("\(model.settings.buses[safe: i]?.name ?? "") → kanal \(c + 1)" + (c < names.count ? " (\(names[c]))" : ""))
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(0..<D, id: \.self) { c in ChannelMeter(channel: c).frame(width: 8, height: 24).frame(width: colW, height: rowH) }
            }
        }
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.muted).padding(.bottom, 6)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Nivåmåler for én buss (oppdateres 25 ganger i sekundet).
struct BusMeter: View {
    @EnvironmentObject var audio: AudioEngine
    @Environment(\.theme) var theme
    let bus: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.04)) { _ in
            let level = audio.mixer?.busLevel(bus) ?? 0
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(theme.panel3)
                    RoundedRectangle(cornerRadius: 2).fill(level >= 0.99 ? theme.danger : theme.running)
                        .frame(width: g.size.width * CGFloat(MeterMath.fraction(level)))
                }
            }
        }
    }
}

/// Nivåmåler for én kanal på lydkortet.
struct ChannelMeter: View {
    @EnvironmentObject var audio: AudioEngine
    @Environment(\.theme) var theme
    let channel: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.04)) { _ in
            let level = audio.mixer?.channelLevel(channel) ?? 0
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1).fill(theme.panel3)
                    RoundedRectangle(cornerRadius: 1).fill(level >= 0.99 ? theme.danger : theme.running)
                        .frame(height: g.size.height * CGFloat(MeterMath.fraction(level)))
                }
            }
        }
    }
}
