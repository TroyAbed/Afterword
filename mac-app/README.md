# Afterword — macOS app

SwiftUI, macOS 14+, sandboxed. Aufnehmen → an `server.py` auf dem Studio →
Transkript + Protokoll in einer durchsuchbaren Bibliothek.

## Bauen

```bash
brew install xcodegen
cd ~/Afterword/mac-app
xcodegen generate && open Afterword.xcodeproj
```

Schema **Afterword** → ⌘R. `project.yml` ist die Wahrheit; die `.xcodeproj` wird
generiert und ist nicht im Repo — nach jedem `git pull` neu generieren.

Beim ersten Start (und nach jedem Rebuild, solange das Signing nicht sitzt —
siehe `../CLAUDE.md`):

- Mikrofon erlauben
- Für Systemton / Fenster-Video: Bildschirmaufnahme erlauben → App neu starten
- Kalender erlauben (nur wenn Auto-Aufnahme genutzt wird)
- **Einstellungen (⌘,) → Server**: URL prüfen. Standard `http://localhost:8756`,
  im Betrieb `http://maxpi:8756`.

## Voraussetzung

`server.py` läuft auf dem Studio (siehe `../README.md`). Kein SSH-Tunnel nötig —
`maxpi` leitet Port 8756 weiter.

## Aufbau

```
Sources/
  AfterwordApp.swift          @main. Baut alle Stores in init(), injiziert via Themed { … }.
  Models/
    Session.swift             Datenmodell. Lenientes init(from:) — fehlende Felder → Default.
                              applySpeakerNames swappt SPEAKER_xx → Namen (client-seitig).
    SessionStore.swift        Bibliothek unter Application Support/Afterword/Sessions/<uuid>/.
  Services/
    ScribeAPI.swift           Multipart-HTTP: submit, job, resummarize, models, voices.
    Transcriber.swift         Upload + Polling + Retry-Loop (queued halten statt Fehler).
    AudioRecorder.swift       Mikro (AVAudioRecorder) + Systemton parallel.
    SystemAudioCapture.swift  ScreenCaptureKit → eigene m4a.
    WindowVideoCapture.swift  Fenster-Video (HEVC, sparsam), Fenster-Erkennung, Live-Preview.
    SessionPlayer.swift       AVPlayer + AVMutableComposition — Video + alle Audiospuren synchron.
    MeetingCalendar.swift     EventKit — laufendes Meeting + Link erkennen.
    MeetingWatcher.swift      Auto-Aufnahme bei Kalender-Meetings mit Link (off/ask/auto).
    SessionExport.swift       Protokoll / Transkript / kombiniert (.md) + Untertitel (.srt).
  Support/
    AppSettings.swift         UserDefaults: Server, Sprache, Modell, Farbweg, Erscheinung.
    Colorway.swift            6 Farbwege (hell+dunkel), Appearance, Themed, Brand (Typo).
    Navigator.swift           Sprung von Suchtreffer ins Transkript.
  Views/
    ContentView.swift         NavigationSplitView + Toolbar-Aufnahmeknopf.
    SidebarView.swift         Liste + Volltextsuche + Umbenennen + Zahnrad → Einstellungen.
    RecordingView.swift       Aufnahme-Sheet: Typ, Titel, Systemton/Video, Fenster-Grid, ⌘M.
    RecordingController.swift  Geteilte start/stop-Logik (Sheet + Menüleiste).
    MenuBarView.swift         Schnellaufnahme + laufendes Meeting + letzte Sessions.
    SessionDetailView.swift   Video, Marker-Chips, Wiedergabe, Protokoll/Transkript, Export.
    SettingsView.swift        Darstellung, Sprache, Server, Kalender, Modell, Stimmen.
Resources/
  {de,en}.lproj/Localizable.strings   Deutsche Keys = Originaltexte.
  Assets.xcassets/AppIcon.appiconset  App-Icon, 10 Grössen, aus der Marke gezeichnet.
```

Nach jedem `../deploy.sh` (Server-Code) wird `uvicorn` auf dem Studio neu
gestartet — Python lädt nicht selbst neu.

Sessions öffnet „Im Finder" im Detail-View. Sie liegen im Sandbox-Container:
`~/Library/Containers/com.troyabed.Afterword/Data/Library/Application Support/Afterword/Sessions/`.
