import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme

    var body: some View {
        Group {
            if let c = model.playhead {
                ScrollView {
                    CueInspector(cue: c)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .id(c.id)
            } else {
                Text("Ingen cue valgt").foregroundColor(theme.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.panel)
    }
}

/// To felt ved siden av hverandre.
struct Pair<A: View, B: View>: View {
    let a: A
    let b: B
    init(@ViewBuilder _ a: () -> A, @ViewBuilder _ b: () -> B) { self.a = a(); self.b = b() }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) { a }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) { b }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CueInspector: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme
    @ObservedObject var cue: Cue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(cue.typeIcon) \(cue.typeName)").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("▶ Test") { model.fire(cue) }.buttonStyle(PanelButtonStyle()).help("Kjør cuen uten å flytte GO-markøren")
                Button("■") { model.stop(cue) }.buttonStyle(PanelButtonStyle()).help("Stopp denne cuen")
            }
            if let e = cue.error {
                Text(e).foregroundColor(theme.danger).font(.system(size: 12)).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) { FieldLabel("Nummer"); TextInput($cue.number, mono: true) }.frame(width: 80)
                VStack(alignment: .leading, spacing: 0) { FieldLabel("Navn"); TextInput($cue.name, placeholder: cue.displayName) }
            }

            typeSection

            Rectangle().fill(theme.line).frame(height: 1).padding(.top, 16).padding(.bottom, 8)
            SectionHeader("AVSPILLING")
            Pair {
                FieldLabel("Pre-wait (s)"); NumberInput(value: $cue.preWait, range: 0...3600)
            } _: {
                FieldLabel("Hurtigtast")
                Button(action: { model.hotkeyCapture = (model.hotkeyCapture === cue) ? nil : cue }) {
                    Text(model.hotkeyCapture === cue ? "Trykk en tast …" : (cue.hotkey.isEmpty ? "(ingen)" : cue.hotkey))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(model.hotkeyCapture === cue ? theme.wait : theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(theme.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.hotkeyCapture === cue ? theme.playhead : theme.line))
                }
                .buttonStyle(.plain)
                .help("Klikk og trykk en tast (F1–F12, A–Z, 0–9). ⌫ fjerner, Esc avbryter.")
            }
            FieldLabel("MIDI-trigger")
            HStack(spacing: 6) {
                Text(cue.midiTrigger.isEmpty ? "(ingen)" : MidiTriggers.describe(cue.midiTrigger))
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.line))
                Button("Lær") { model.learnMidi(for: cue) }.buttonStyle(PanelButtonStyle())
                    .help("Klikk, og trykk så en tast/knapp på MIDI-kontrolleren")
                Button("✕") { model.cancelLearn(); cue.midiTrigger = "" }.buttonStyle(PanelButtonStyle())
            }
            if !model.learnText.isEmpty { Hint(model.learnText).foregroundColor(theme.wait) }

            FieldLabel("Etterpå")
            Picker("", selection: $cue.continueMode) {
                ForEach(ContinueMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden()
            Toggle("Deaktivert (hoppes over av GO)", isOn: $cue.disabled).padding(.top, 8)

            FieldLabel("Farge")
            HStack(spacing: 6) {
                ForEach(CueColor.allCases, id: \.self) { c in
                    Button { model.setColor(c) } label: {
                        ZStack {
                            Circle().fill(theme.stripe(c) ?? Color.clear).frame(width: 14, height: 14)
                            if c == .none {
                                Circle().stroke(theme.faint, lineWidth: 1.5).frame(width: 14, height: 14)
                                Rectangle().fill(theme.faint).frame(width: 1.5, height: 16).rotationEffect(.degrees(45))
                            }
                        }
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 5).fill(theme.panel3))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(cue.color == c ? theme.playhead : theme.line))
                    }
                    .buttonStyle(.plain)
                    .help(c.label)
                }
            }

            FieldLabel("Notater (vises ved NESTE CUE)")
            TextEditor(text: $cue.notes)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 54)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.line))
        }
    }

    // MARK: Typespesifikt

    @ViewBuilder private var typeSection: some View {
        switch cue.type {
        case .audio: audioSection
        case .video: videoSection
        case .image, .pdf: stillSection
        case .fade: fadeSection
        case .stop: stopSection
        case .osc: oscSection
        case .midi: midiSection
        }
    }

    private var filePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel(cue.type == .audio ? "Lydfil" : cue.type == .video ? "Videofil" : cue.type == .pdf ? "PDF-fil" : "Bildefil")
            HStack(spacing: 6) {
                Text(cue.filePath.isEmpty ? "(ingen fil)" : cue.filePath)
                    .lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.line))
                    .help(cue.filePath)
                Button("Velg …") { model.browseFile(for: cue) }.buttonStyle(PanelButtonStyle())
            }
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            filePicker
            if cue.fileDuration > 0 { Hint("Filens lengde: \(TimeFormat.format(cue.fileDuration)) · \(cue.fileChannels) kanal(er)") }
            Pair {
                FieldLabel("Nivå (dB)"); NumberInput(value: $cue.volumeDb, range: -60...12)
            } _: {
                FieldLabel("Loop"); Toggle("Gjenta til stoppet", isOn: $cue.loop).padding(.top, 4)
            }
            Pair {
                FieldLabel("Start (s)"); NumberInput(value: $cue.startTime, range: 0...86400)
            } _: {
                FieldLabel("Slutt (s, 0 = filslutt)"); NumberInput(value: $cue.endTime, range: 0...86400)
            }
            Pair {
                FieldLabel("Fade inn (s)"); NumberInput(value: $cue.fadeIn, range: 0...600)
            } _: {
                FieldLabel("Fade ut (s)"); NumberInput(value: $cue.fadeOut, range: 0...600)
            }
            Hint("Fade ut brukes ved stopp og automatisk mot slutten av fila.")
            FieldLabel("Utganger (dB per filkanal → utgang)").padding(.top, 6)
            RoutingMatrixView(cue: cue)
            Hint("Skriv nivå i dB (0 = fullt), tomt = av. Endringer høres med en gang hvis cuen spiller. Utgangene settes opp under Lydpatch.")
        }
    }

    private var visualCommon: some View {
        VStack(alignment: .leading, spacing: 0) {
            Pair {
                FieldLabel("Fade inn (s)"); NumberInput(value: $cue.fadeIn, range: 0...600)
            } _: {
                FieldLabel("Fade ut (s)"); NumberInput(value: $cue.fadeOut, range: 0...600)
            }
            FieldLabel("Skalering")
            Picker("", selection: $cue.stretch) {
                ForEach(VisualStretch.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden()
            Toggle("Erstatt andre bilder/videoer (krysstoning)", isOn: $cue.replaceOthers).padding(.top, 8)
        }
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            filePicker
            Pair {
                FieldLabel("Lydnivå (dB)"); NumberInput(value: $cue.volumeDb, range: -60...12)
            } _: {
                FieldLabel("Loop"); Toggle("Gjenta til stoppet", isOn: $cue.loop).padding(.top, 4)
            }
            visualCommon
            FieldLabel("Lydspor → utganger (dB)").padding(.top, 6)
            if cue.hasNoAudio { Hint("Videoen har ikke noe lydspor.") }
            RoutingMatrixView(cue: cue)
            Hint("Lyden i videoen pakkes ut og spilles av ShowCue sin lydmotor, så den går gjennom lydpatchen (Dante o.l.) og holdes i synk med bildet. «Alt av» gjør videoen stum.")
            Button("Pakk ut lyd til egen lyd-cue …") { model.extractVideoAudio(cue) }
                .buttonStyle(PanelButtonStyle()).padding(.top, 10)
                .help("Lagrer lydsporet som WAV ved siden av videoen og lager en lyd-cue som starter samtidig. Videoen gjøres stum.")
        }
    }

    private var stillSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            filePicker
            if cue.type == .pdf {
                FieldLabel("Side")
                HStack(spacing: 6) {
                    IntInput(value: $cue.page, range: 1...100_000)
                    Button("+ Cue for neste side") { model.pdfNextPage(cue) }.buttonStyle(PanelButtonStyle())
                        .help("Lager en ny PDF-cue for neste side rett under denne")
                }
            }
            FieldLabel("Vis i (s, 0 = til stoppet)")
            NumberInput(value: $cue.holdTime, range: 0...86400)
            visualCommon
        }
    }

    private var fadeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("Mål-cue (nummer)"); TextInput($cue.target, mono: true)
            FieldLabel("Fade-tid (s)"); NumberInput(value: $cue.fadeTime, range: 0...600)
            Toggle("Fade lyd til nivå (dB):", isOn: $cue.fadeAudio).padding(.top, 8)
            NumberInput(value: $cue.targetDb, range: -60...12).disabled(!cue.fadeAudio).padding(.leading, 20).padding(.top, 4)
            Hint("−60 eller lavere = stille.").padding(.leading, 20)
            Toggle("Fade bilde/video til synlighet (%):", isOn: $cue.fadeVisual).padding(.top, 8)
            NumberInput(value: $cue.targetOpacity, range: 0...100).disabled(!cue.fadeVisual).padding(.leading, 20).padding(.top, 4)
            Toggle("Stopp mål-cuen når faden er ferdig", isOn: $cue.stopWhenDone).padding(.top, 8)
        }
    }

    private var stopSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("Mål-cue (nummer, tomt = stopp alt)"); TextInput($cue.target, mono: true)
            FieldLabel("Fade-tid (s)"); NumberInput(value: $cue.fadeTime, range: 0...600)
        }
    }

    private var oscSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) { FieldLabel("IP-adresse / vertsnavn"); TextInput($cue.host) }
                VStack(alignment: .leading, spacing: 0) { FieldLabel("Port"); IntInput(value: $cue.port, range: 1...65535) }.frame(width: 90)
            }
            FieldLabel("Adresse"); TextInput($cue.address, mono: true)
            FieldLabel("Argumenter"); TextInput($cue.arguments, mono: true)
            Hint("Skill med mellomrom. 1 = heltall, 0.5 = desimaltall, true/false, ellers tekst. Bruk \"anførselstegn\" for tekst med mellomrom.")
            Hint("Eksempel X32: adresse /ch/01/mix/fader  argument 0.75")
        }
    }

    private var midiSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("MIDI-utgang")
            Picker("", selection: $cue.device) {
                Text("(første tilgjengelige)").tag("")
                ForEach(MidiSystem.destinations(), id: \.self) { Text($0).tag($0) }
                if !cue.device.isEmpty && !MidiSystem.destinations().contains(cue.device) { Text("\(cue.device) (ikke tilkoblet)").tag(cue.device) }
            }.labelsHidden()
            FieldLabel("Meldingstype")
            Picker("", selection: $cue.messageType) {
                ForEach(MidiMessageType.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden()
            if cue.messageType == .mscGo {
                FieldLabel("MSC cue-nummer"); TextInput($cue.mscCueNumber, mono: true)
                Pair {
                    FieldLabel("Device ID (127 = alle)"); IntInput(value: $cue.mscDeviceId, range: 0...127)
                } _: {
                    FieldLabel("Command format"); IntInput(value: $cue.mscCommandFormat, range: 0...127)
                }
                Hint("Command format 1 = lys (general), 16 = lyd.")
            } else {
                FieldLabel("Kanal (1–16)"); IntInput(value: $cue.channel, range: 1...16)
                FieldLabel("Note / program / controller (0–127)"); IntInput(value: $cue.data1, range: 0...127)
                if cue.messageType == .noteOn || cue.messageType == .controlChange {
                    FieldLabel("Velocity / verdi (0–127)"); IntInput(value: $cue.data2, range: 0...127)
                }
            }
        }
    }
}

// MARK: - Routingmatrise

/// Rader = kanaler i lydfila, kolonner = utganger i lydpatchen. Hver rute er dB; tom = ikke routet.
struct RoutingMatrixView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme
    @ObservedObject var cue: Cue

    private var rows: Int { max(1, min(16, cue.fileChannels > 0 ? cue.fileChannels : 2)) }

    var body: some View {
        let buses = model.settings.buses
        let routes = cue.effectiveRoutes(fileChannels: rows)
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow {
                        Text("")
                        ForEach(buses.indices, id: \.self) { b in
                            Text("\(b + 1)").font(.system(size: 11)).foregroundColor(theme.muted).frame(width: 38).help("Utgang \(b + 1): \(buses[b].name)")
                        }
                    }
                    ForEach(0..<rows, id: \.self) { r in
                        GridRow {
                            Text(rows == 1 ? "Mono" : rows == 2 ? (r == 0 ? "Venstre" : "Høyre") : "Kanal \(r + 1)")
                                .font(.system(size: 11.5)).foregroundColor(theme.muted).padding(.trailing, 6).gridColumnAlignment(.leading)
                            ForEach(buses.indices, id: \.self) { b in
                                let route = routes.first { $0.source == r + 1 && $0.bus == b + 1 }
                                RouteCell(initial: route.map { Cue.fmt($0.gainDb) } ?? "", active: route != nil,
                                          help: "Kanal \(r + 1) → \(buses[b].name)") { text in
                                    commit(src: r + 1, bus: b + 1, text: text)
                                }
                                .id("\(cue.id)-\(r)-\(b)-\(route?.gainDb ?? -999)")
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            HStack(spacing: 6) {
                Button("Standard") { cue.routes = nil }.help("Mono → 1+2, stereo → 1/2 osv.")
                Button("Alt av") { cue.routes = [] }
                Button("Sum til mono") {
                    let ch = max(1, cue.fileChannels > 0 ? cue.fileChannels : 2)
                    let g = ch > 1 ? -6.0 : 0
                    cue.routes = (1...ch).flatMap { [AudioRoute($0, 1, g), AudioRoute($0, 2, g)] }
                }.help("Alle kanaler til utgang 1 og 2")
            }
            .buttonStyle(PanelButtonStyle())
            .font(.system(size: 11.5))
        }
    }

    private func commit(src: Int, bus: Int, text: String) {
        var list = cue.effectiveRoutes(fileChannels: rows)
        let idx = list.firstIndex { $0.source == src && $0.bus == bus }
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "-" || t == "-inf" || t == "av" {
            guard let i = idx else { return }
            list.remove(at: i)
        } else {
            guard let db = Double(t.replacingOccurrences(of: ",", with: ".")) else { cue.objectWillChange.send(); return }
            let v = min(12, max(-60, db))
            if let i = idx {
                if abs(list[i].gainDb - v) < 0.001 { return }
                list[i].gainDb = v
            } else {
                list.append(AudioRoute(src, bus, v))
            }
        }
        cue.routes = list.sorted { ($0.source, $0.bus) < ($1.source, $1.bus) }
    }
}

private struct RouteCell: View {
    @Environment(\.theme) var theme
    let initial: String
    let active: Bool
    let help: String
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    init(initial: String, active: Bool, help: String, onCommit: @escaping (String) -> Void) {
        self.initial = initial
        self.active = active
        self.help = help
        self.onCommit = onCommit
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 12))
            .frame(width: 38, height: 24)
            .background(RoundedRectangle(cornerRadius: 3).fill(active ? theme.runningRow : theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(focused ? theme.playhead : theme.line))
            .focused($focused)
            .onSubmit { onCommit(text); NSApp.keyWindow?.makeFirstResponder(nil) }
            .onChange(of: focused) { f in if !f && text != initial { onCommit(text) } }
            .help(help)
    }
}
