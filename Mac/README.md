# ShowCue for Mac

Egen Mac-app skrevet i Swift. Den bruker Apples egne rammeverk (CoreAudio, AVFoundation, PDFKit og CoreMIDI) og trenger ingen tilleggsprogrammer.
Den har de samme funksjonene som Windows-versjonen, og **showfilene (`.showcue`) kan åpnes på begge plattformene**.

Krever macOS 13 (Ventura) eller nyere. Kjører både på Apple Silicon og Intel.

## Bygge og starte

**Enklest, med Xcode** (gratis fra App Store):
1. Dobbeltklikk `Package.swift`. Xcode åpner prosjektet.
2. Velg «My Mac» øverst og trykk ▶ (⌘R).

**Lage ShowCue.app** (Xcode eller Command Line Tools, `xcode-select --install`):
```
cd Mac
./build-app.sh
open build/ShowCue.app
```
Dra `build/ShowCue.app` til Programmer-mappa.

**Med GitHub:** legger du prosjektet i et GitHub-repo, bygger `.github/workflows/mac.yml` appen og kjører testene automatisk.
Den ferdige appen ligger under *Actions → siste kjøring → Artifacts → ShowCue-Mac*.
Apper lastet ned fra nettet er ikke signert. Høyreklikk og velg **Åpne** første gang, eller kjør
`xattr -dr com.apple.quarantine /Applications/ShowCue.app`.

Første gang du starter appen, spør macOS om tilgang til **lokalt nettverk**. Si ja, ellers virker ikke OSC.

## Dante Virtual Soundcard og flerkanals lydkort

DVS på Mac er en vanlig CoreAudio-enhet:
1. Start Dante Virtual Soundcard. Velg antall kanaler i DVS og samplingsfrekvens i Dante Controller.
2. ShowCue → **Innstillinger → Lyd**: velg «Dante Virtual Soundcard». Alle kanalene åpnes, opptil 64 som standard.
3. **Lydpatch** (i verktøylinja): kryss av hvilke Dante-kanaler hver utgang skal på. Du kan linjesjekke med **Test** (rosa støy på −18 dBFS).
   Rut kanalene videre i Dante Controller.

Det samme gjelder andre kort (RME, MOTU, Focusrite, Behringer X-USB/Wing) og aggregerte enheter laget i Lyd- og MIDI-oppsett.
Samplingsfrekvensen følger enheten, og filer med en annen frekvens konverteres automatisk av høy kvalitet.

## Forskjeller fra Windows-versjonen

| | Mac | Windows |
|---|---|---|
| Lyddriver | CoreAudio (alle enheter, også Dante DVS) | WASAPI eller ASIO |
| Lydformater | WAV, AIFF, MP3, M4A/AAC, ALAC, FLAC, CAF | WAV, AIFF, MP3, M4A/AAC, FLAC, WMA |
| Videoformater | MP4, MOV, M4V (H.264, HEVC, ProRes) | MP4, MOV, WMV, AVI, MKV (H.264 tryggest) |
| Innstillinger | `~/Library/Application Support/ShowCue/` | `%AppData%\ShowCue\` |
| Zoom i bølgeform | Knip på styreflaten eller −/+ | Musehjul |
| Hurtigtaster | F-tastene krever `fn`, med mindre «Bruk F1, F2 osv. som standard funksjonstaster» er slått på | |

Alt annet er likt: cuetyper, start/slutt-redigering med bølgeform og forhåndslytting, routingmatrise, lydpatch, videolyd gjennom patchen, OSC/MIDI inn og ut, MSC, status til Companion, temaer og cuefarger.
Se README i Windows-mappa for full beskrivelse av OSC-kommandoer og Companion-variabler.

**Showfiler mellom Mac og Windows:** stiene til mediefilene er forskjellige på de to plattformene. ShowCue leter derfor etter mediefiler
ved siden av showfila og i en undermappe `Media`, så legg showfil og media i samme mappe når du flytter mellom maskiner.
Show lagret på Mac krever Windows-versjon 0.4 eller nyere.

## Tastatur

| Tast | Funksjon |
|---|---|
| Mellomrom | GO |
| Esc | Stopp alt (to ganger = umiddelbart) |
| ↑ / ↓ | Flytt GO-markøren |
| ⌘1 … ⌘8 | Legg til lyd, video, bilde, PDF, fade, stopp, OSC, MIDI |
| ⌘D, ⌘⌫, ⌘↑/⌘↓ | Dupliser, slett, flytt |
| ⌘S, ⇧⌘S, ⌘O, ⌘N | Lagre, lagre som, åpne, nytt |
| ⇧⌘T | Bytt tema |
| ⇧⌘U | Vis/skjul utgangsvinduet |
| ⌘, | Innstillinger |

Klikk velger, ⌘-klikk velger flere og ⇧-klikk velger et område. Dobbeltklikk tester cuen. Høyreklikk åpner en meny med farge, aktiver/deaktiver og dupliser.
Du kan dra filer fra Finder rett inn i lista.

## Oppbygning

```
Sources/ShowCue/
  Core/    Modeller (samme JSON som Windows), OSC, status til Companion, fjernstyring,
           MIDI-tolking, mikser (PatchMixer, Voice, ringbuffer). Testes automatisk.
  Audio/   CoreAudio-utgang (AUHAL), enheter, dekoding i egen tråd (AVAudioFile / AVAssetReader)
  Engine/  Cue-motor, aktive cuer, video/bilde/PDF-utgang, CoreMIDI, app-modell
  UI/      SwiftUI: hovedvindu, cueliste, inspektør, routingmatrise, lydpatch, innstillinger, temaer
Tests/     XCTest (kjøres med «swift test» eller ⌘U i Xcode)
```

Lydtråden leser bare ferdig dekodet lyd fra ringbuffere. En egen tråd dekoder, og hovedtråden styrer cuene.
Lyden venter derfor aldri på disk eller brukergrensesnitt.
