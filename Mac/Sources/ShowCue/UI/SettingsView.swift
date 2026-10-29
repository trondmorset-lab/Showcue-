import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) var theme
    @State private var draft = AppSettings()
    @State private var loaded = false
    @State private var devices: [AudioDeviceInfo] = []
    @State private var midiInputs: [String] = []
    @State private var learning: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                page { audioTab }.tabItem { Text("Lyd") }
                page { videoTab }.tabItem { Text("Video") }
                page { oscTab }.tabItem { Text("OSC") }
                page { midiTab }.tabItem { Text("MIDI inn") }
                page { lookTab }.tabItem { Text("Utseende") }
                page { safetyTab }.tabItem { Text("Sikkerhet") }
            }
            HStack {
                Text(draft.audioKey != model.settings.audioKey ? "Nytt lydoppsett stopper alt som spiller." : "")
                    .font(.system(size: 11.5)).foregroundColor(theme.wait)
                Spacer()
                Button("Tilbakestill") { draft = model.settings }
                Button("Bruk") { model.applySettings(draft); draft = model.settings }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 580, height: 640)
        .background(theme.panel)
        .onAppear {
            if !loaded { draft = model.settings; loaded = true }
            devices = CoreAudioDevices.outputDevices()
            midiInputs = MidiSystem.sources()
        }
        .onDisappear { model.router.cancelLearn() }
    }

    private func page<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { c() }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Lyd

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("Lydenhet")
            Picker("", selection: $draft.audioDeviceUID) {
                Text("Systemets standard utgang").tag("")
                ForEach(devices) { Text($0.label).tag($0.uid) }
            }.labelsHidden()
            Hint("Dante Virtual Soundcard, flerkanals USB/Thunderbolt-kort og aggregerte enheter vises her. Alle kanalene åpnes (opptil maks nedenfor), og lydpatchen bestemmer hvor hver utgang går.")
            Pair {
                FieldLabel("Maks antall kanaler"); IntInput(value: $draft.maxChannels, range: 2...512)
            } _: {
                FieldLabel("Buffer (rammer)")
                Picker("", selection: $draft.bufferFrames) {
                    ForEach([64, 128, 256, 512, 1024], id: \.self) { Text("\($0)").tag($0) }
                }.labelsHidden()
            }
            Hint("Lavere buffer gir raskere respons på GO. 256 er trygt for de fleste; øk ved knaking.")
            Hint("Samplingsfrekvensen følger enheten (for Dante: settes i Dante Controller). Filer med annen frekvens konverteres automatisk.")
            Button("Oppdater liste") { devices = CoreAudioDevices.outputDevices() }.buttonStyle(PanelButtonStyle()).padding(.top, 10)
        }
    }

    // MARK: Video

    private var videoTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("Utgang for video, bilde og PDF")
            Picker("", selection: $draft.videoScreen) {
                Text("Vindu (ikke fullskjerm)").tag(-1)
                ForEach(Array(OutputCompositor.screenNames().enumerated()), id: \.offset) { i, n in Text(n).tag(i) }
            }.labelsHidden()
            Hint("Velg projektoren/skjermen. «Vindu» gir et vanlig vindu, nyttig for å teste på én skjerm.")
        }
    }

    // MARK: OSC

    private var oscTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Ta imot OSC (fjernstyring fra Companion, TouchOSC, lysbord …)", isOn: $draft.oscInEnabled)
            FieldLabel("UDP-port"); IntInput(value: $draft.oscInPort, range: 1...65535)
            let ips = UDP.localAddresses()
            Hint(ips.isEmpty ? "Fant ingen nettverksadresser." : "Send til: \(ips.joined(separator: "  eller  "))  (port \(draft.oscInPort)). Fra samme maskin: 127.0.0.1.")
            FieldLabel("Kommandoer").padding(.top, 8)
            VStack(alignment: .leading, spacing: 3) {
                ForEach([("/go", "GO"), ("/stop", "stopp alt (med fade)"), ("/panic", "som Esc (2× = umiddelbart)"),
                         ("/hardstop", "stopp alt umiddelbart"), ("/next  /previous", "flytt markøren"),
                         ("/playhead/12", "sett markøren til cue 12"), ("/cue/12/start", "start cue 12"),
                         ("/cue/12/stop", "stopp cue 12"), ("/cue/12/go", "markør til 12 + GO"),
                         ("/hotkey/F1", "som å trykke F1"), ("/refresh", "send status på nytt")], id: \.0) { a, b in
                    HStack(spacing: 0) {
                        Text(a).frame(width: 150, alignment: .leading)
                        Text(b).foregroundColor(theme.muted)
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.panel2))
            Hint("Argument 0 ignoreres (knapp sluppet). macOS kan spørre om tilgang til lokalt nettverk første gang – tillat det.")

            Rectangle().fill(theme.line).frame(height: 1).padding(.vertical, 14)
            SectionHeader("STATUS UT (TIL COMPANION)")
            Toggle("Send status: neste cue, hva som spiller, tid igjen", isOn: $draft.oscFeedbackEnabled).padding(.top, 6)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) { FieldLabel("Mottaker (IP)"); TextInput($draft.oscFeedbackHost) }
                VStack(alignment: .leading, spacing: 0) { FieldLabel("Port"); IntInput(value: $draft.oscFeedbackPort, range: 1...65535) }.frame(width: 100)
            }
            FieldLabel("Format")
            Picker("", selection: $draft.oscFeedbackFormat) {
                ForEach(OscFeedbackFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden()
            Hint("Companion: setter egendefinerte variabler (Custom Variables) via Companions OSC-port (standard 12321). Opprett variablene i Companion først: sc_next_name, sc_next_number, sc_playing, sc_remaining, sc_state m.fl. – se README. Bruk dem i knappetekst som $(internal:custom_sc_next_name).")
            Hint("Generisk: /showcue/next/name, /showcue/remaining … og /showcue/cue/{nr}/running 1/0.")
        }
    }

    // MARK: MIDI

    private var midiTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("MIDI-inngang")
            Picker("", selection: $draft.midiInDevice) {
                Text("(av)").tag("")
                ForEach(midiInputs, id: \.self) { Text($0).tag($0) }
                if !draft.midiInDevice.isEmpty && !midiInputs.contains(draft.midiInDevice) {
                    Text("\(draft.midiInDevice) (ikke tilkoblet)").tag(draft.midiInDevice)
                }
            }.labelsHidden()
            FieldLabel("Kanal")
            Picker("", selection: $draft.midiInChannel) {
                Text("Alle kanaler").tag(0)
                ForEach(1...16, id: \.self) { Text("Kanal \($0)").tag($0) }
            }.labelsHidden()

            FieldLabel("Faste funksjoner").padding(.top, 8)
            learnRow("GO", \.midiGo)
            learnRow("Stopp alt", \.midiStopAll)
            learnRow("Neste", \.midiNext)
            learnRow("Forrige", \.midiPrevious)
            Hint("«Lær»: klikk, og trykk en tast/knapp på kontrolleren. Lær bruker inngangen som er aktiv nå – bytter du inngang, trykk «Bruk» først. Hver cue kan også få sin egen MIDI-trigger i panelet til høyre i hovedvinduet.")

            Toggle("Ta imot MIDI Show Control (MSC GO / STOP med cuenummer)", isOn: $draft.mscInEnabled).padding(.top, 14)
            FieldLabel("MSC device ID (127 = alle)"); IntInput(value: $draft.mscInDeviceId, range: 0...127)
        }
    }

    private func learnRow(_ label: String, _ key: WritableKeyPath<AppSettings, String>) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundColor(theme.muted).frame(width: 90, alignment: .leading)
            Text(learning == label ? "Venter på MIDI …" : (draft[keyPath: key].isEmpty ? "(ingen)" : MidiTriggers.describe(draft[keyPath: key])))
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(learning == label ? theme.wait : theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.line))
            Button("Lær") {
                guard model.midi.isInputOpen else {
                    model.alert("Ingen MIDI-inngang er aktiv ennå. Velg inngang og trykk «Bruk» først.")
                    return
                }
                learning = label
                model.router.beginLearn { t in
                    draft[keyPath: key] = t
                    learning = nil
                }
            }
            Button("✕") { model.router.cancelLearn(); learning = nil; draft[keyPath: key] = "" }
        }
        .buttonStyle(PanelButtonStyle())
        .padding(.vertical, 3)
    }

    // MARK: Utseende og sikkerhet

    private var lookTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("Fargetema")
            Picker("", selection: Binding(get: { model.settings.theme }, set: { t in model.settings.theme = t; draft.theme = t })) {
                ForEach(AppTheme.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            Hint("Mørk passer de fleste kontrollrom. Lys er lettest å lese i dagslys og på prøver. Nattmodus er ekstra dempet for mørke scener og sidescene. Temaet byttes med en gang (også med ☀︎-knappen i verktøylinja eller ⇧⌘T).")
        }
    }

    private var safetyTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("Stopp alt: fade-tid (s)"); NumberInput(value: $draft.panicFadeTime, range: 0...30)
            FieldLabel("Dobbel-GO-sperre (ms)"); IntInput(value: $draft.doubleGoProtectionMs, range: 0...2000)
            Hint("GO ignoreres hvis det kommer innen denne tiden etter forrige GO (prell på tast eller kontroller).")
        }
    }
}
