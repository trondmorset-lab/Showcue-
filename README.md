# ShowCue

Showavvikling for Windows og Mac.

Cue-basert avspillingsprogram for konsert, event og teater, i samme ånd som QLab.
Det finnes i to utgaver som deler showformat:

| Mappe | Plattform | Teknologi | Bygging |
|---|---|---|---|
| `Windows/` | Windows 10/11 | C# / .NET 8 / WPF / NAudio | `build.bat`, eller Visual Studio |
| `Mac/` | macOS 13+ | Swift / SwiftUI / CoreAudio / AVFoundation | Åpne `Package.swift` i Xcode, eller `./build-app.sh` |

Begge har:
- Cuer for lyd, video, bilde, PDF, fade, stopp, OSC og MIDI
- **Start og slutt med bølgeform**, zoom og forhåndslytting gjennom lydpatchen
- Pre-wait, auto-continue og auto-follow
- Hurtigtaster og MIDI-triggere per cue
- **Lydpatch** for flerkanals lydkort og Dante, med routingmatrise per cue, testtone og nivåmålere
- **Lyd i video** som går gjennom lydpatchen og holdes i synk med bildet
- **Fjernstyring** med OSC inn (QLab-lignende kommandoer), MIDI inn og MSC
- **Status til Companion** over OSC: neste cue, hva som spiller og tid igjen
- **Lys, mørk og nattmodus**, og cuefarger som i QLab

Showfiler (`.showcue`) kan flyttes fritt mellom Mac og Windows. Legg mediefilene i samme mappe som showet,
eller i en undermappe `Media`.

## Last ned

Ferdige programmer ligger under **Releases** på GitHub:
- **ShowCue x.y.z** – utgitte versjoner, med endringene i utgivelsesteksten.
- **Siste bygg** – bygges automatisk ved hver endring på main, for å teste det nyeste.

Windows: `ShowCue.exe`. Mac: `ShowCue-Mac.zip` (pakk ut, høyreklikk på appen og velg *Åpne* første gang).

## Versjoner og endringslogg

Versjonsnummeret står i `VERSION` og brukes av både Windows- og Mac-bygget. Endringer føres i `CHANGELOG.md`.
Når `VERSION` økes og endringen kommer til main, lager GitHub Actions en ny utgivelse `v<versjon>` med teksten fra endringsloggen.
Testene kjøres ved hvert bygg.

Se `Windows/README.md` og `Mac/README.md` for detaljer.
