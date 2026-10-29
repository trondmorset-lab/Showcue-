# ShowCue

Cue-basert avspillingsprogram for Windows, i samme ånd som QLab. Laget for konsert og event:
GO-knapp med cueliste, hurtigtaster for jingler og walk-in, og utgang til projektor.

## Bygge programmet

1. Installer **.NET 8 SDK** (ikke bare runtime): https://dotnet.microsoft.com/download/dotnet/8.0
2. Dobbeltklikk `build.bat`.
3. Ferdig program: `publish\ShowCue.exe` (én fil, trenger ingen installasjon – kan kopieres til show-PC-en).

Alternativt: åpne `ShowCue.sln` i Visual Studio 2022 og trykk F5.
Legger du hele prosjektet på GitHub, bygger `.github/workflows/windows.yml` exe-fila automatisk.

Krever Windows 10 (1809) eller nyere, 64-bit.

## Cue-typer

| Type | Hva den gjør |
|---|---|
| ♪ **Lyd** | WAV, MP3, AIFF, FLAC, M4A/AAC, WMA. Nivå (dB), start-/sluttpunkt, loop, fade inn/ut. |
| ▶ **Video** | MP4, MOV, WMV, AVI, MKV. Lyden pakkes ut og går gjennom lydpatchen (se under). Loop, fade, krysstoning. |
| ▣ **Bilde** | PNG, JPG, BMP, GIF, TIFF. Valgfri visningstid, fade, krysstoning. |
| ▤ **PDF** | Viser én side. «+ Cue for neste side» lager raskt en cue per side (sangtekster, presentasjoner). |
| ◢ **Fade** | Fader en kjørende cue til et nytt lydnivå og/eller synlighet, valgfritt stopp etterpå. |
| ■ **Stopp** | Stopper én cue (eller alt, hvis mål er tomt), med valgfri fade. |
| ⇢ **OSC** | Sender OSC over UDP til mikser, lysbord, Companion o.l. Støtter int, float, tekst, true/false. |
| ♫ **MIDI** | Note on/off, program change, CC og MSC GO (MIDI Show Control). |

Alle cues har **pre-wait** (forsinkelse før start), **auto-continue** (start neste samtidig),
**auto-follow** (start neste når denne er ferdig), **hurtigtast**, **MIDI-trigger** og **notater**.

## Lydpatch og flerkanals lydkort (Dante, ASIO)

Lyden går i tre ledd:

```
lydfil-kanaler ──(routing per cue)──▶ utganger ──(lydpatch)──▶ kanaler på lydkortet
```

- **Utganger** (busser) er logiske, f.eks. «Main L», «Main R», «Monitor», «Opptak». Showfila refererer bare
  til utgangene, så showet kan flyttes til en annen maskin med et annet lydkort – bare patchen må endres.
- **Lydpatch** (knapp i verktøylinja): én rad per utgang og én kolonne per kanal på lydkortet. Kryss av for
  hvor hver utgang skal ut. En utgang kan gå til flere kanaler. Nivå per utgang i dB.
  **Test** spiller rosa støy (−18 dBFS) på utgangen for linjesjekk, og nivåmålere vises per utgang og per kanal.
  Med ASIO vises kanalnavnene fra driveren (f.eks. Dante-kanalene) når du holder musa over kolonneoverskriften.
- **Routing per lyd-cue**: matrisen i panelet til høyre, med filkanaler som rader og utganger som kolonner. Skriv nivå i dB,
  eller dobbeltklikk en rute for å slå av/på. «Standard» betyr mono → 1+2, stereo → 1/2, og flerkanalsfiler kanal for kanal.
  Endringer i routing og nivå høres med en gang mens cuen spiller.

**Lyd i video («de-embedding»):** lydsporet i videofiler dekodes av Windows (Media Foundation: AAC, PCM, WMA …)
og spilles av ShowCue sin egen lydmotor. Det går gjennom lydpatchen og ASIO/Dante akkurat som en lyd-cue, med
routingmatrise, nivå i dB, fader og fade-cuer. Lyden styrer tiden: hvis bildet glir mer enn 0,12 s
(f.eks. fordi Dante-klokka og PC-klokka går litt ulikt), justeres bildet. Knappen **«Pakk ut lyd til egen lyd-cue»**
lagrer lydsporet som WAV ved siden av videoen og lager en lyd-cue som starter samtidig. Da kan lyden redigeres
for seg (start/slutt, loop) eller byttes ut med en egen miks.

**Dante Virtual Soundcard:**
1. Start DVS i **ASIO-modus** og velg antall kanaler (f.eks. 64×64) og samplingsfrekvens i Dante Controller.
2. ShowCue → *Innstillinger → Lyd*: velg **ASIO** og driveren «Dante Virtual Soundcard (x64)».
3. *Lydpatch*: kryss av hvilke Dante-kanaler hver utgang skal på. Rut kanalene videre i Dante Controller.

DVS i WDM-modus (og andre flerkanals kort uten ASIO) fungerer også via **WASAPI**. Da brukes enhetens kanaler
og samplingsfrekvens direkte. ASIO anbefales for lavest forsinkelse.

## Fjernstyring: OSC og MIDI inn

**OSC** (UDP, port 53000 som standard – samme som QLab, så mange Companion-oppsett kan gjenbrukes):

| Adresse | Funksjon |
|---|---|
| `/go` | GO |
| `/stop` | Stopp alt (med panikk-fade) |
| `/panic` | Som Esc (to ganger innen 1 s = umiddelbart) |
| `/hardstop` | Stopp alt umiddelbart |
| `/next`, `/previous` | Flytt GO-markøren |
| `/playhead/{nr}` eller `/select/{nr}` | Sett markøren til cue |
| `/cue/{nr}/start` | Start cue (markøren flyttes ikke) |
| `/cue/{nr}/stop` | Stopp cue (med cuens fade ut) |
| `/cue/{nr}/go` eller `/go/{nr}` | Sett markøren til cue og kjør GO |
| `/hotkey/{tast}` | Som å trykke hurtigtasten, f.eks. `/hotkey/F1` |

- Cuenummer kan også sendes som argument: `/cue/start "12"`.
- Meldinger med argument 0 eller false ignoreres, så knapper som sender «sluppet» ikke trigger to ganger.
- Prefikset `/showcue/...` er også tillatt. OSC-bundles støttes.
- Statuslinja nederst viser porten, maskinens IP-adresser og siste mottatte melding.
- Windows-brannmuren spør første gang: tillat ShowCue på private nettverk.

**Bitfocus Companion / Stream Deck:** bruk modulen «Generic OSC», sett mål-IP til show-PC-en og port 53000,
og send f.eks. `/go` eller `/cue/5/start`.

### Status tilbake til Companion (OSC ut)

*Innstillinger → OSC → Status ut*: skriv inn IP-adressen til Companion-maskinen og port **12321**
(Companions OSC-port; slå på OSC under *Settings → Protocols* i Companion).

**Format «Companion»** setter egendefinerte variabler. Opprett disse under *Variables → Custom Variables* i Companion
(du trenger bare dem du vil bruke):

| Variabel | Innhold | Eksempel |
|---|---|---|
| `sc_next_number`, `sc_next_name`, `sc_next_notes` | Cuen ved GO-markøren | `3`, `Intro-video` |
| `sc_playing`, `sc_playing_number` | Sist startede cue som spiller | `Applaus-jingle` |
| `sc_playing_all` | Alle som spiller | `Walk-in · Applaus-jingle` |
| `sc_playing_count` | Antall som spiller | `2` |
| `sc_remaining`, `sc_remaining_name` | Tid igjen på cuen som slutter først | `-0:05` |
| `sc_elapsed` | Tid spilt på sist startede cue | `1:23` |
| `sc_running` | Nummer på alle som spiller | `1,7` |
| `sc_playhead` | Markørens posisjon | `3/11` |
| `sc_state` | `klar`, `venter` (pre-wait) eller `spiller` | |
| `sc_show` | Navn på showet | |

Bruk dem i knappetekst, f.eks. `$(internal:custom_sc_next_name)`, og i feedback (f.eks. rød knapp når
`sc_state` = `spiller`). Bare endrede verdier sendes (ca. 10 ganger i sekundet), pluss alt hvert 5. sekund.
Companion kan be om alt på nytt med `/refresh`.

**Format «Generisk»** sender `/showcue/next/name`, `/showcue/remaining`, `/showcue/playing/count` (heltall) osv.,
pluss `/showcue/cue/{nr}/running 1|0` når en cue starter og stopper. Passer for andre programmer eller moduler som lytter på OSC.

**MIDI inn** (*Innstillinger → MIDI inn*):
- Velg inngang og kanal (eller alle).
- **Faste funksjoner:** GO, Stopp alt, Neste og Forrige kan knyttes til en note, CC eller program change med **Lær**.
- **Per cue:** «MIDI-trigger» i panelet til høyre. Trykk **Lær** og deretter en tast/knapp på kontrolleren.
  Cuen startes, eller stoppes hvis den allerede spiller, akkurat som en hurtigtast.
- CC trigger når verdien går fra under 64 til 64 eller mer, så en fader ikke trigger hele tiden.
- **MIDI Show Control:** GO og STOP med cuenummer fra lysbord o.l., med valgfri device ID.

OSC og MIDI **ut** gjøres med OSC- og MIDI-cuer i cuelista.

## Betjening

| Tast | Funksjon |
|---|---|
| **Mellomrom** | GO – kjør cuen ved markøren og flytt til neste |
| **Esc** | Stopp alt med kort fade. Trykk igjen innen 1 s for umiddelbar stopp |
| **↑ / ↓** | Flytt GO-markøren |
| **F1–F12, A–Z, 0–9** | Hurtigtaster (start/stopp cuen uten å flytte markøren) |
| **Ctrl+1 … Ctrl+8** | Legg til lyd, video, bilde, PDF, fade, stopp, OSC, MIDI |
| **Ctrl+D** | Dupliser |
| **Ctrl+↑ / Ctrl+↓** | Flytt cue opp/ned |
| **Delete** | Slett valgte cues |
| **Ctrl+S / Ctrl+O / Ctrl+N** | Lagre / åpne / nytt show |
| **Enter** (i et felt) | Bekreft og gå tilbake til lista |

- **Dra filer** fra Utforsker rett inn i cuelista.
- **Dobbeltklikk** en cue for å teste den uten å flytte markøren.
- Hurtigtaster på lyd/bilde/video fungerer som av/på: trykk én gang for å starte, én gang til for å stoppe (med cuens fade ut).
- F-tastene virker også mens du skriver i et felt; bokstaver og tall gjør det ikke.
- GO har dobbel-GO-sperre (300 ms) så tasteprell ikke hopper over en cue.

## Utseende

Tre fargetemaer, som byttes med en gang via ☀-knappen i verktøylinja eller *Innstillinger → Utseende*:
**Mørk** (grafitt, som QLab 5), **Lys** (dagslys og prøver) og **Nattmodus** (ekstra dempet for mørke scener).
Tittellinja i Windows følger temaet.

**Cuefarger:** gi cuer en farge (rød, oransje, gul, grønn, blå, lilla, grå) i panelet til høyre. Raden blir tonet,
og hurtigknappen får en fargestripe. Velg flere cuer for å farge alle på én gang.
Farger er tilpasset hvert tema (dempet i mørk og natt, pastell i lys).

## Innstillinger

- **Lyd:** WASAPI (vanlige lydkort/USB/Dante WDM) eller **ASIO** (Dante Virtual Soundcard, RME, Focusrite …).
  Faller automatisk tilbake til Windows standardenhet hvis valgt kort mangler. Se *Lydpatch* over.
- **OSC inn / MIDI inn:** se *Fjernstyring* over.
- **Video/bilde/PDF-utgang:** velg skjerm/projektor for fullskjerm, eller «Vindu» for testing på én skjerm.
  Utgangen vises også som forhåndsvisning nede til høyre.
- Innstillinger og lydpatch lagres per maskin i `%AppData%\ShowCue\settings.json`.

## Showfiler

Shows lagres som `.showcue` (lesbar JSON). Flytter du showet til en annen maskin, legg mediefilene
i samme mappe som showfila eller i en undermappe `Media` – da finner ShowCue dem automatisk.
Manglende filer merkes med rødt **!** i lista.

## Mac-versjon

Det finnes en egen Mac-versjon i mappa `Mac/`. Showfilene kan deles: show lagret på Mac åpnes i Windows-versjon 0.4+,
og show fra Windows åpnes på Mac. ShowCue finner mediefilene igjen hvis de ligger ved siden av showfila eller i en undermappe `Media`.

## Kjente begrensninger i versjon 0.4

- Video spilles med Windows' innebygde mediemotor. MP4/H.264 med AAC-lyd er tryggest; enkelte MKV/HEVC-filer
  kan kreve kodeker fra Microsoft Store. Videoer med flere lydspor: bare det første brukes.
- Bilde og lyd starter samtidig når videoen er åpnet. Store 4K-filer kan bruke litt tid på å åpne – legg gjerne
  inn et lite pre-wait på cuen før i stedet for å trykke GO i siste sekund.
- Ingen angre-funksjon ennå – lagre ofte.
- Ingen gruppe-cues eller timecode ennå.

## Mappestruktur

```
ShowCue/
  Models/      Cue-typer, showfil og innstillinger
  Engine/      Lydmotor: PatchMixer (busser → kanaler), CuePlayback (routing, fades),
               AudioEngine (WASAPI/ASIO), VideoAudio, OSC inn/ut, OscFeedback, MIDI inn/ut,
               RemoteControl, cue-motor
  Views/       Utgangsvindu, innstillinger, lydpatch, routingmatrise, temabytte
  Themes/      Colors.Dark/Light/Night.xaml (farger) og Controls.xaml (stiler)
  MainWindow   Hovedvindu: cueliste, GO, inspector, aktive cues, hurtigtaster
```
