# Endringslogg

Alle endringer som merkes av brukere, nyeste først. Versjonsnummeret står i fila `VERSION`.
Hver versjon får en egen utgivelse på GitHub (`v0.5.0` osv.) med Windows- og Mac-programmet.
Utgivelsen «siste» bygges på nytt ved hver endring og viser det nyeste, også det som ikke er gitt ut ennå.

## 0.5.0 – 2026-10-30

### Nytt
- **Redigering av start og slutt med bølgeform** for lyd- og video-cuer: dra den grønne (start) og røde (slutt)
  markøren, området utenfor er mørklagt, og fade inn/ut vises i bølgeformen.
- **Forhåndslytting gjennom lydpatchen**: fra start, fra markøren eller de siste 5 sekundene før slutt, uten å påvirke showet.
  «Start = markør» og «Slutt = markør» kan trykkes mens det spiller.
- Zoom (musehjul på Windows, knip eller −/+ på Mac) og et eget **stort redigeringsvindu**.
- **Video-cuer har start- og sluttpunkt.** Bilde og lyd starter på startpunktet og holdes i synk, og loop går mellom punktene.
- Versjonsnummeret vises i vindustittelen.

### Endret
- Panikk / Stopp alt stopper også forhåndslytting.

## 0.4.0 – 2026-10-29

Første utgave på GitHub, for både Windows og Mac.

- Cuetyper: lyd, video, bilde, PDF, fade, stopp, OSC og MIDI (inkl. MSC).
- Lydpatch for flerkanals lydkort (Dante, ASIO/CoreAudio) med routingmatrise per cue.
- Lyden i videoer går gjennom lydpatchen og holdes i synk med bildet.
- Fjernstyring med OSC, MIDI og MSC, og status tilbake til Companion over OSC.
- Lyst, mørkt og natt-tema, og cuefarger som i QLab.
- Showfiler kan deles mellom Windows og Mac.
