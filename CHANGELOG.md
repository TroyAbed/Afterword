# Changelog

## Unveröffentlicht

- Sprecher-Zuordnung pro Wort statt pro Whisper-Segment — trennt Wortwechsel
  mitten im Satz sauber, statt den ganzen Satz einer Person zuzuschlagen.
- Meetings gehen jetzt von mindestens zwei Sprechern aus.
- Protokoll: `temperature = 0` und der Prompt ist strenger gegen Erfinden —
  Unklares wird als unklar benannt statt ergänzt. **Das Modell auf dem Studio
  ist der grösste Hebel:** `gpt-oss:20b` neu ziehen oder `qwen3:14b`, ein
  Code-Modell taugt für Fliesstext-Protokolle wenig.
- Ein halb eingetippter „Ollama-Server"-Wert wird ignoriert statt jede
  Zusammenfassung mit einem DNS-Fehler abzubrechen.

## 0.3

**Aufnahme**
- Dateien importieren statt aufzunehmen — Audio oder Video. Ein Video bleibt als
  Videospur der Session erhalten; der Server zieht die Tonspur mit ffmpeg raus.
- Mikrofon wählbar — in den Einstellungen als Standard, pro Aufnahme und in der
  Menüleiste änderbar.
- Sprecherzahl vorgeben (Automatisch / 1–8), wenn die automatische Erkennung
  daneben liegt. Auf einer fertigen Aufnahme: **Falsche Sprecherzahl?** → neu
  transkribieren.
- Videoqualität in drei Stufen (Sparsam / Standard / Bildschirm), Standard in den
  Einstellungen, pro Aufnahme überschreibbar. Das Video wird immer hart gedeckelt
  (max. 4 GB, dann läuft nur noch der Ton weiter).

**Transkript & Protokoll**
- Neues Report-Format: Zusammenfassung → Besprochene Punkte → Entscheidungen →
  Offene Punkte → To-dos. To-dos sind namensführend: `**Name**: Aufgabe (Frist)`.
  Bei einem einzelnen Sprecher fällt die Namensnennung weg.
- „Namen & Begriffe" in den Einstellungen — hilft dem Transkript, Namen und
  Fachbegriffe richtig zu schreiben. Gespeicherte Stimmen werden automatisch
  ergänzt.
- Klick auf einen Suchtreffer in der Seitenleiste springt jetzt direkt zur
  Textstelle im Transkript und hebt sie kurz hervor.
- Eigenes Ollama für das Protokoll eintragbar (Einstellungen → Protokoll-Modell →
  Ollama-Server).

**Export**
- Titel + Datum stehen jetzt auch im `.srt`-Export (erste Untertitel-Zeile).
- Der Protokoll-Header listet die benannten Sprecher.

**Behoben**
- Absturz beim Öffnen einer Aufnahme mit Video auf Apple-Silicon-Macs (die App
  ist jetzt ein Universal-Build und nutzt AppKits `AVPlayerView` statt SwiftUIs
  `VideoPlayer`).

**Server** — braucht `./deploy.sh`: Sprecherzahl, Vokabular, das neue
Report-Format und der frei eintragbare Ollama-Server hängen am Server-Code bzw.
an `config.toml`. Fertige Aufnahmen bekommen das neue Format über „Neu erstellen".

## 0.2

Erste Version, die als Release verteilt wurde. Aufnahme (Mikro + Systemton +
Fenster-Video), Transkription + deutsches Protokoll auf dem Mac Studio,
durchsuchbare Bibliothek, Marker, Stimmen-Bibliothek, Kalender-Auto-Aufnahme,
Markdown-/SRT-Export, sechs Farbwege, DE/EN-Oberfläche.
