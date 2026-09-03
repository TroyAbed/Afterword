# Afterword

Lokale, offline Meeting-Transkription für macOS. Ein Gespräch, einen Call oder
einen eigenen Brainstorm aufnehmen → nach Sprechern getrenntes Transkript +
strukturiertes deutsches Protokoll. Die ganze Rechenarbeit läuft auf einem
**Mac Studio (M2 Ultra)** im lokalen Netz — nichts geht in eine Cloud.

Es ist ein **persönliches Werkzeug**: Gespräche im Nachgang nochmal durchgehen,
To-dos rausziehen, Voice Notes behalten. Ausdrücklich **kein**
Vertriebs-Gesprächsrecorder — kein Redeanteil-Coaching, kein CRM-Push, keine
BANT-Vorlagen.

```
┌─────────────┐   Audio (+ Systemton, + Fenster-Video)     ┌──────────────────┐
│  Afterword  │  ────────────────────────────────────────▶  │   server.py      │
│  (mac-app,  │            HTTP, Bearer-Token                │  (Mac Studio,    │
│  dein Mac)  │  ◀────────────────────────────────────────  │   M2 Ultra)      │
└─────────────┘        transcript.md + summary.md            └──────────────────┘
                                                               mlx-whisper
                                                               pyannote-Diarisierung
                                                               Ollama-Summary
```

## Aufbau des Repos

| Pfad | Was |
|---|---|
| `pipeline.py` | Der Kern: Audio → WAV → ASR (mlx-whisper) → Diarisierung (pyannote) → Sprecher-Zuordnung → Markdown → Ollama-Summary. Wird von allen drei Frontends importiert. |
| `server.py` | FastAPI-Dienst, mit dem die App spricht. Zweiphasiger Job-Worker (erst Transkript, dann Protokoll), Job-Zustand auf der Platte, Stimmen-Bibliothek. |
| `scribe.py` | CLI über `pipeline.py` — `python scribe.py meeting.m4a`. |
| `watch.py` | Ordner-Watcher: Dateien in `inbox/`, Transkripte landen in `output/`. |
| `client.py` | Datei von deinem Mac an den laufenden Dienst schicken und auf das Ergebnis warten. |
| `voices.py` | Stimmen-Bibliothek — diarisierte Sprecher per Cosinus-Ähnlichkeit gegen gespeicherte Stimm-Embeddings matchen, damit wiederkehrende Personen automatisch benannt werden. |
| `remote.sh` | Der alte SSH-Weg (funktioniert noch; abgelöst durch `client.py` + Dienst). |
| `config.toml` | Alle Modell-/Prompt-/Schwellenwert-Einstellungen. Liegt beim Code, wird mit ihm deployt. |
| `deploy.sh` | Python + `config.toml` + LaunchAgent auf den Studio schieben, Dienst neu starten. |
| `uninstall-studio.sh` | Alles wieder entfernen, was das Projekt auf dem Studio installiert hat. |
| `com.afterword.server.plist` | LaunchAgent, damit der Dienst auf dem Studio automatisch startet. |
| `pi/ollama_proxy.py` | TCP-Proxy auf einem Raspberry Pi (`maxpi`), damit Tailscale-Geräte den Studio unter einer festen Adresse erreichen (Ports 11434 Ollama + 8756 Afterword). |
| `mac-app/` | Die macOS-App (SwiftUI, macOS 14+). Siehe `mac-app/README.md`. |
| `linux-app/` | Der Linux-Client (PySide6/Qt). Siehe `linux-app/README.md`. |
| `design/` | Der Design-Canvas (Claude Design): Hauptfenster, Einstellungen, Farbwege, Aufnahme-Sheet. |

## Der Server (Mac Studio)

Läuft in `~/whisper-service/` auf dem Studio (Benutzer `maurusronner`), ein
Python-3.12-venv mit `mlx-whisper`, `pyannote.audio`, `fastapi`, `uvicorn`. Die
Modelle liegen vorab in `~/whisper-service/models/`, der Code erzwingt
`HF_HUB_OFFLINE=1` — zur Laufzeit wird Hugging Face nie kontaktiert.

### Pipeline-Stufen (`pipeline.py`)

1. **`prepare_wav`** — ffmpeg → mono 16 kHz WAV. Wenn eine Systemton-Spur
   mitkommt, wird sie mit `amix` + `dynaudnorm` eingemischt (Mikro und App-Ton
   haben meist sehr unterschiedliche Pegel).
2. **`transcribe_segments`** — `mlx_whisper.transcribe` auf Metal, Wort-Zeitstempel,
   `condition_on_previous_text=False`. ~92 s Audio in ~17 s kalt.
3. **`diarize`** — `pyannote/speaker-diarization-community-1`, gefüttert mit einem
   Waveform-Tensor über `soundfile` (braucht so nie `torchcodec`), MPS wenn die
   Kernels vorhanden sind. Liefert `(turns, embeddings)` — die Embeddings pro
   Sprecher speisen die Stimmen-Bibliothek.
4. **`assign_speakers`** — jedes ASR-Segment bekommt den Sprecher, mit dem es sich
   am stärksten überlappt.
5. **`format_markdown`** — fasst aufeinanderfolgende Segmente desselben Sprechers
   zu `**SPEAKER_00** · h:mm:ss`-Blöcken zusammen.
6. **`summarize`** — schickt das Transkript an Ollama `/api/chat`. Das Modell wird
   beim Aufruf aufgelöst (`_pick_model`): das konfigurierte Modell, oder der erste
   `fallback_models`-Eintrag, der tatsächlich installiert ist — auf dem geteilten
   Studio werden Modelle immer wieder entfernt.

### Dienst (`server.py`)

`uvicorn server:app --host 0.0.0.0 --port 8756`. Ein Hintergrund-Worker-Thread,
ein Job nach dem anderen. Job-Zustand ist ein Ordner pro Job unter
`~/whisper-service/data/<id>/` (`meta.json`, `audio.*`, `system.*`,
`transcript.md`, `summary.md`, `segments.json`, `embeddings.json`).

Zwei Phasen, damit das Transkript lesbar ist, während das Protokoll noch läuft:
`queued → running → transcribed → done` (oder `error`, mit gespeichertem
Traceback). Beim Neustart wird alles mit Status `queued`/`running` neu eingereiht.

| Endpoint | Anmerkung |
|---|---|
| `GET /health` | `{ok, queued}` — ohne Auth |
| `GET /models` | installierte Ollama-Modelle + welches „Automatisch" gerade wählt |
| `POST /jobs` | multipart: `audio`, optional `system_audio`, `kind`, `title`, `language`, `summary_model` |
| `GET /jobs` · `GET /jobs/{id}` | Job-Liste / ein Job (+ Transkript, Protokoll, Segmente) |
| `POST /jobs/{id}/resummarize` | Protokoll mit eingesetzten Sprechernamen neu erzeugen |
| `GET /jobs/{id}/audio` | der Original-Upload |
| `GET/POST /voices` · `DELETE /voices/{name}` · `POST /voices/{name}/pop` | Stimmen-Bibliothek |

Alle Endpoints ausser `/health` brauchen `Authorization: Bearer <token>`, **wenn**
`~/whisper-service/app/token.txt` existiert. `deploy.sh` fasst diese Datei nie an.

### Deploy

```bash
cd ~/Afterword
./deploy.sh                 # scp *.py + config.toml + Plist, Dienst neu starten
```

Fragt nach dem Studio-Passwort (kein dauerhafter SSH-Key). Killt ausserdem einen
übrig gebliebenen `com.meetingscribe.server`-Agenten von vor der Umbenennung,
damit sich die beiden nicht um Port 8756 streiten.

**Nach jedem Deploy wird der Dienst für dich neu gestartet — startest du `uvicorn`
je von Hand, musst du nach einem Deploy selbst neu starten. Python lädt nicht
automatisch neu.**

### Autostart

`com.afterword.server.plist` → `~/Library/LaunchAgents/`, `launchctl bootstrap
gui/$(id -u) …`. `RunAtLoad` + `KeepAlive`. Die Plist trägt `HF_HOME` /
`TORCH_HOME` / `HF_HUB_OFFLINE` in `EnvironmentVariables`, weil launchd `uvicorn`
direkt startet, ohne das `activate` des venv zu sourcen.

### Entfernen

```bash
scp uninstall-studio.sh maurusronner@mac-studio-von-maurus.local:~/
ssh … 'bash ~/uninstall-studio.sh'
rm ~/Library/LaunchAgents/com.afterword.server.plist
```

Entfernt den LaunchAgent, `~/whisper-service/` (venv, alle Modelle, alle
Aufnahmen), verstreute Caches, den HF-Token aus dem Schlüsselbund und `ffmpeg` +
`python@3.12` **nur wenn brew keine anderen Abhängigen zeigt**. Ollama bleibt.

## Die App (`mac-app/`)

SwiftUI, macOS 14+, sandboxed. XcodeGen-Projekt — `project.yml` ist die
Wahrheit, die `.xcodeproj` wird generiert und ist git-ignoriert.

```bash
brew install xcodegen
cd ~/Afterword/mac-app
xcodegen generate && open Afterword.xcodeproj   # Schema „Afterword" → ⌘R
```

Nimmt Mikro + (bei Meetings) Systemton über ScreenCaptureKit auf + optional das
Meeting-Fenster als Video (bleibt lokal, wird nie hochgeladen; Qualität in drei
Stufen, immer hart gedeckelt). Lädt zum Dienst
hoch, pollt, zeigt erst Transkript, dann Protokoll. **Dateien importieren** (Audio oder Video) statt aufzunehmen. **Mikrofon wählbar**
(Einstellungen + pro Aufnahme). **Sprecherzahl vorgeben** wenn die automatische
Erkennung daneben liegt. **Namen & Begriffe** für bessere Schreibweisen im
Transkript. Bibliothek mit Volltextsuche über alle Transkripte, Marker (⌘M),
sprecherübergreifende Stimmenerkennung, kalendergesteuerte Auto-Aufnahme,
Markdown-/SRT-Export.

Sechs Farbwege (Schwefel ist Standard), hell/dunkel/System, deutsche oder
englische Oberfläche — alles in **Einstellungen** (⌘, oder das Zahnrad unten in
der Seitenleiste).

Das **Ollama für das Protokoll** ist in den Einstellungen frei eintragbar
(`Protokoll-Modell → Ollama-Server`) — leer heisst „der Studio nutzt sein
eigenes", sonst wird die Summary-Anfrage an die angegebene Adresse geschickt.

Aufnahmen liegen im Sandbox-Container:
`~/Library/Containers/com.troyabed.Afterword/Data/Library/Application Support/Afterword/Sessions/`.

## Netzwerk

Die App zeigt auf `http://maxpi:8756` (in **Einstellungen → Server**). `maxpi` ist
ein Raspberry Pi im Tailscale-Netz mit `pi/ollama_proxy.py`, das 8756 (und 11434
für Ollama) an den Studio weiterleitet und den mDNS-Namen des Studios pro
Verbindung neu auflöst — eine wechselnde DHCP-Lease auf dem Studio ist damit egal.
Jedes Tailscale-Gerät erreicht den Dienst, kein SSH-Tunnel offen zu halten.

Ein **schlafender** Studio ist trotzdem nicht erreichbar — im Studio den
Ruhezustand abschalten.

## Rechtliches

Nicht-öffentliche Gespräche in der Schweiz aufzunehmen braucht die Zustimmung
aller Beteiligten (Art. 179bis / 179ter StGB). Die Aufnahme ansagen.

## Release / Download

Die App wird nicht ins Repo eingecheckt — sie hängt als `.dmg` an einem
**GitHub-Release**.

```bash
./release.sh 0.2            # baut Release + .dmg, taggt v0.2, lädt es hoch (gh auth nötig)
./release.sh 0.2 --dmg-only # nur die .dmg nach dist/, kein Release
```

`release.sh` baut **universal** (arm64 + x86_64) — die Build-Maschine ist Intel,
die Zielgeräte meist nicht. Von Hand geht es auch: `dist/Afterword-<ver>.dmg` bauen (`./release.sh <ver> --dmg-only`),
dann auf github.com → **Releases → Draft a new release**, Tag `v<ver>`, die `.dmg`
in „Attach binaries" ziehen, **Publish**.

Installieren: `.dmg` öffnen, App nach „Programme" ziehen. Die App ist ad-hoc
signiert (kein bezahlter Apple-Developer-Account), also einmalig:

```bash
xattr -dr com.apple.quarantine /Applications/Afterword.app
```

Danach normal öffnen. Server-URL in **Einstellungen → Server** setzen.

## Design-Canvas

<https://claude.ai/code/artifact/7ddbc5bb-b1e0-4a2c-ba83-96a4c9a8b675>

## Weiteres

- `CHANGELOG.md` — Änderungen je Version (auch die Release-Notes).

- `CLAUDE.md` — ausführliche Architektur- und Zustandsdoku (auch für eine neue Claude-Session).
- `mac-app/README.md` — Detailaufbau der macOS-App.
- `linux-app/README.md` — der Linux-Client (CachyOS/Arch: `makepkg -si`).
