# ShowCue

Showavvikliing for Windows og Mac.

Cue-basert avspillingsprogram for konsert, event og teater, i samme ånd som QLab.
Det finnes i to utgaver som deler showformat:

| Mappe | Plattform | Teknologi | Bygging |
|---|---|---|---|
| `Windows/` | Windows 10/11 | C# / .NET 8 / WPF / NAudio | `build.bat`, eller Visual Studio |
| `Mac/` | macOS 13+ | Swift / SwiftUI / CoreAudio / AVFoundation | Åpne `Package.swift` i Xcode, eller `./build-app.sh` |

Begge har:
- Cuer for lyd, video, bilde, PDF, fade, stopp, OSC og MIDI
- Pre-wait, auto-continue og auto-follow
- Hurtigtaster og MIDI-triggere per cue
- **Lydpatch** for flerkanals lydkort og Dante, med routingmatrise per cue, testtone og nivåmålere
- **Lyd i video** som går gjennom lydpatchen og holdes i synk med bildet
- **Fjernstyring** med OSC inn (QLab-lignende kommandoer), MIDI inn og MSC
- **Status til Companion** over OSC: neste cue, hva som spiller og tid igjen
- **Lys, mørk og nattmodus**, og cuefarger som i QLab

Showfiler (`.showcue`) kan flyttes fritt mellom Mac og Windows. Legg mediefilene i samme mappe som showet,
eller i en undermappe `Media`.

**GitHub:** legger du hele mappa i et GitHub-repo, bygger `.github/workflows/` både `ShowCue.exe` og `ShowCue.app` automatisk.
Testene kjøres også. De ferdige filene finner du under *Actions → Artifacts*.

Se `Windows/README.md` og `Mac/README.md` for detaljer.
