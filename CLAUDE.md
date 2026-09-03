# Afterword — working notes for Claude

This file is context for a future Claude session picking up this repo. It records
the things that are **not obvious from the code**: the three machines, the deploy
dance, the design history and why it landed where it did, and the work that is
still open.

Written 2026-09-02, just after the app was renamed **MeetingScribe → Afterword**.

---

## 1. What this is

A personal, offline meeting-transcription tool. The user is starting at a Swiss
solar company and wanted an outbound-research pipeline; **this is the second,
separate project** — a tool for re-reading their own conversations, brainstorms
and calls, and pulling out to-dos. The user corrected an earlier framing
explicitly: **it is not a sales-call recorder.** Do not add talk-ratio coaching,
CRM push, BANT templates, or anything that assumes a customer on the other end.
Three use cases: (1) in-room meetings, (2) Teams/Zoom calls, (3) solo brainstorms.

## 2. The machines

| Name | What | Reached how |
|---|---|---|
| **Mac Pro (2019, Intel, 96 GB)** | the user's machine. Editing, `deploy.sh`, running the app. macOS Tahoe, Homebrew. | — |
| **Mac Studio (M2 Ultra, 192 GB)** | all compute: `server.py`, mlx-whisper, pyannote, Ollama. User `maurusronner` (the user's brother/family). | `maurusronner@mac-studio-von-maurus.local` over SSH (password each time — **no key is planted**), or `http://maxpi:8756`. |
| **Raspberry Pi `maxpi`** | Tailscale node, runs `pi/ollama_proxy.py` (systemd `--user` unit `ollama-proxy.service`). Forwards `:8756`→Studio:8756 and `:11434`→Studio:11434, re-resolving the Studio's mDNS name per connection. | `maurusronner@maxpi` / Tailscale |
| MacBook Air M1 8 GB | possible capture device; can't run the full stack. | — |

- The Mac Pro **cannot reach the Studio directly over Wi-Fi** — the "MAXIP"
  network has client isolation. That is why `maxpi` exists as a relay.
- The Studio is a **shared** machine. The brother uses its Ollama (Cline, etc.)
  and **removes models** to free space — hence `_pick_model` / `fallback_models`.
- Ollama on the Studio is run by a hand-written `~/Library/LaunchAgents/ollama.network.plist`
  (`OLLAMA_HOST=0.0.0.0 KEEP_ALIVE=-1 NUM_PARALLEL=3 …`). **Do not touch it.**
  Afterword's LaunchAgent sits next to it, same pattern.
- SSH access for Claude was **deliberately removed** at the user's request. There
  is no `~/.ssh/id_*`, no ControlMaster socket, no config entry. `deploy.sh`
  prompts for the password each run. Do not re-establish persistent SSH.

## 3. Server side

`~/whisper-service/` on the Studio: a Python 3.12 venv (`.venv/`), models in
`models/`, deployed code in `app/`, job data in `data/`, voice library in
`voices/`, optional `app/token.txt` for bearer auth, `server.log`.

`deploy.sh` scps `pipeline.py voices.py scribe.py server.py watch.py client.py
config.toml` + the plist into `~/whisper-service/app/`, then boots the service.

### Gotchas that have bitten before

- **Python has no hot-reload.** After a deploy, `uvicorn` must restart. `deploy.sh`
  does this. If you ever `nohup uvicorn … &` by hand, a later deploy leaves the
  old process serving stale code — this exact bug silently dropped system audio
  once.
- **launchd runs `uvicorn` directly**, not through `source .venv/bin/activate`.
  So `HF_HOME` / `TORCH_HOME` / `HF_HUB_OFFLINE` must be set both in
  `pipeline.py` (`os.environ.setdefault` at module top) **and** in the plist's
  `EnvironmentVariables`. Missing them → pyannote tries to fetch the gated repo →
  401.
- **PATH is thin** in a non-interactive shell — misses Homebrew's ffmpeg.
  `pipeline.py` prepends `/opt/homebrew/bin` and `/usr/local/bin`.
- **`torchcodec` vs ffmpeg 8** — incompatible. It was uninstalled; `diarize`
  feeds pyannote a waveform tensor via `soundfile` so it never needs torchcodec.
- **pyannote API drift** — newer versions return `DiarizeOutput` (has
  `.speaker_diarization`, `.exclusive_speaker_diarization`, `.speaker_embeddings`),
  older return an `Annotation`. `diarize()` handles both.
- **HF token** — used once for the gated pyannote download, then revoked on the
  web. `HF_HUB_OFFLINE=1` everywhere. Treat any HF token as sensitive.
- **Migrated off whisperx** (2026-09-01) — it was CPU-only CTranslate2 (~20 min
  per hour of audio, starved the brother's Ollama). mlx-whisper uses the GPU.
  whisperx is still pip-installed (torch/pyannote came in through it) but its ASR
  path is dead. An old `Systran/faster-whisper-large-v3` CT2 model (~3 GB) may
  still be in the HF cache and can be deleted.

### `config.toml`

- `[transcribe]` — `mlx_model`, `diarize_model`, `diarize_device` (default `mps`),
  `language` (`de`), `initial_prompt` (CH vocab bias — Alp, Sennerei, kWp,
  Dachpacht…), optional `min_speakers` / `max_speakers`.
- `[summary]` — `ollama_url`, `ollama_model`, `fallback_models` (ordered list),
  `num_ctx`, `temperature`, and **`prompt`**. The prompt fixes the report shape:
  `## Zusammenfassung / Besprochene Punkte / Entscheidungen / Offene Punkte /
  To-dos`, To-dos as `- **SPEAKER_00**: task (Frist)` (name first), one-speaker
  sessions drop the name. Speaker refs stay verbatim `**SPEAKER_00**` so the
  client substitutes real names locally. `MarkdownText` renders `##` as an
  uppercase section head. No per-job/per-app prompt override yet — would be a
  `prompt` form field like `summary_model`. **`[voices]` must stay at the end of the file**
  — a TOML section after `[summary]` once swallowed `[summary].prompt`.
- `[voices]` — `match_threshold` (0.62; needs tuning once real voices are enrolled).

### Two-phase worker

`server.py` `_worker()`: `transcribe_and_diarize` → save `transcript.md` +
`segments.json` + `embeddings.json`, run `voice_lib.match` → status `transcribed`
→ `summarize` → status `done`. Errors store `error` + `traceback` in `meta.json`.
On boot, `queued`/`running` jobs are re-queued.

`POST /jobs` also accepts `speaker_count` (0 = auto; N forces
`min_speakers=max_speakers=N` in `cfg["transcribe"]`) and `vocab` (a name/term
list appended to `initial_prompt` — the app builds it from the user's
"Namen & Begriffe" setting **plus every saved voice name**).

`POST /jobs` / `/jobs/{id}/resummarize` accept an optional `ollama_url` form
field (and `/models` an `?ollama_url=` query) — the app exposes it as
**Einstellungen → Protokoll-Modell → Ollama-Server** so a user can point the
summary step at their own Ollama. Empty falls back to `config.toml`.

The client's summary shows `SPEAKER_00` etc.; names are swapped **client-side** on
every render (`Session.applySpeakerNames`) — instant, no LLM re-run. This was the
user's idea and it is better than the resummarize approach. `resummarize` is kept
as a manual escape hatch (after transcript edits, or a failed summary).

## 4. The app (`mac-app/`)

SwiftUI, macOS 14+, sandboxed, **universal binary** (build machine is Intel —
always `ARCHS="arm64 x86_64"`, `release.sh` does it). Bundle id `com.troyabed.Afterword`. XcodeGen:
`project.yml` → `xcodegen generate` → `Afterword.xcodeproj` (**git-ignored,
regenerate after pulling**). Dev language `de`, localized `de` + `en`.

### Structure

```
Sources/
  AfterwordApp.swift        @main. Builds SessionStore / AppSettings / Transcriber /
                            AudioRecorder / RecordingController / MeetingWatcher /
                            Navigator in init(), injects via `Themed { … }.environmentObject(…)`.
                            WindowGroup(id:"main") + MenuBarExtra + Settings.
  Models/
    Session.swift           The record. `SessionKind`, `SessionStatus` (recording/
                            uploading/processing/transcribed/done/error, .isBusy,
                            .hasTranscript), `TranscriptSegment`. **Explicit lenient
                            init(from:)** — every field `decodeIfPresent ?? default`.
                            Add new fields the same way or old sessions fail to load
                            (silently, swallowed by `try?`). `applySpeakerNames`
                            swaps SPEAKER_xx → names in transcript + summary;
                            unnamed → "Sprecher N+1". `speakerGroups`, `markers`.
    SessionStore.swift      @MainActor. Sessions under
                            Application Support/Afterword/Sessions/<uuid>/
                            {meta.json, audio.m4a, system.m4a, video.mp4,
                             transcript.md, summary.md}. (The pre-rename container
                            migration shim was removed — the sandbox blocks
                            cross-container access anyway.)
  Services/
    ScribeAPI.swift         Multipart HTTP. `submit` (audio + optional system_audio),
                            `job`, `resummarize`, `models`, voice CRUD.
    Transcriber.swift       Drives a session: upload → poll every 4 s → store.
                            **Retry loop** — `run` wraps `attemptRun`; network/5xx
                            keeps the session `.uploading` with
                            "Warte auf den Server … (Versuch n)", backs off to 60 s;
                            4xx fails immediately. `running: Set<UUID>` guard.
                            `resumePending()` = sweep + a 60 s Timer so anything
                            busy is picked up when the Studio wakes.
    AudioRecorder.swift     Mic via **AVCaptureSession + AVCaptureAudioFileOutput**
                            (was AVAudioRecorder — switched so a specific input
                            device can be chosen; level from the file output's
                            AVCaptureAudioChannel.averagePowerLevel). + (meetings)
                            SystemAudioCapture in parallel, each its own m4a.
    MicDevices.swift        Enumerates input devices for the mic pickers
                            (AVCaptureDevice.DiscoverySession). Env object.
    SystemAudioCapture.swift  ScreenCaptureKit `SCStream`, `capturesAudio=true`,
                            display filter, writes system.m4a. Falls back to
                            mic-only if Screen Recording isn't granted.
    WindowVideoCapture.swift  `SCContentFilter(desktopIndependentWindow:)`,
                            AVAssetWriter HEVC (H.264 fallback). Quality from a
                            `VideoQuality` preset (Sparsam/Standard/Bildschirm —
                            854–1600 px, 5–10 fps, ≤ ~1.1 GB/h). Hard file cap at
                            `WindowVideoCapture.maxBytes` (4 GB): video stops,
                            audio continues. `windows()`, `thumbnail(of:)`,
                            `likelyMeetingWindow`/`meetingScore` (bundle id + title
                            heuristics: Zoom "Zoom Meeting" not "Zoom Workplace",
                            Teams Besprechung, Webex, Slack huddle, meet.google /
                            zoom.us / teams.microsoft browser tabs). `onPreview`
                            (~3 fps CGImage) for the live preview. **Video is local
                            only, never uploaded** — the app combines it with the
                            audio tracks at playback.
    SessionPlayer.swift     `AVPlayer` + `AVMutableComposition` — video track (if
                            any) + every audio track on one timeline → perfect
                            sync. Loads in `Task.detached` with a `loadToken` guard
                            (Thread Performance Checker fix).
    MeetingCalendar.swift   EventKit (`requestFullAccessToEvents`) — reads the
                            macOS Calendar, which already aggregates Google /
                            Outlook / iCloud. Finds the event running now, extracts
                            a meeting link by regex from url/notes/location.
                            `startPolling()` every 20 s.
    MeetingWatcher.swift    20 s tick. Only fires for events **with a link** (a
                            plain calendar block is ignored). `off` / `ask`
                            (default, banner in the menu bar) / `auto` (starts
                            recording straight away). Auto-stop when the watched
                            window is gone > 30 s, or event end + 15 min.
    SessionExport.swift     protocol / transcript / combined `.md` + `.srt`,
                            NSSavePanel + NSSharingServicePicker.
  Support/
    VideoQuality.swift      3 meeting-video presets (see WindowVideoCapture).
    AppSettings.swift       UserDefaults-backed. serverURL, token, language
                            (spoken), summaryModel, autoRecordMode, colorway,
                            appearance, uiLanguage. `uiLocale` → nil = follow system.
    Colorway.swift          `Palette` (paper, side, ink, onInk, line, muted,
                            accent, onAccent, **accentText** = accent darkened for
                            legible small text, isDark). Six `Colorway` cases
                            (schwefel default, saeure, zinnober, bleiRost,
                            signalblau, magenta), each light + dark. `Appearance`
                            light/dark/system. `Themed` wraps a scene: resolves
                            palette, injects `\.palette` + `\.locale`, sets `.tint`
                            + `.preferredColorScheme`. `Brand` = type layer (SF Pro,
                            weights only — see below).
    Navigator.swift         `SeekRequest(session, time, token)` for
                            search-result → transcript jumps.
  Views/
    ContentView.swift       NavigationSplitView. Toolbar "Aufnehmen" button.
    SidebarView.swift       Session list + `.searchable` full-text search across
                            title/summary/segments; matching lines shown as
                            clickable snippet rows (→ `navigator.jump`). Rows are
                            **hand-drawn** (Button + custom background), NOT
                            List(selection:) — the system fills a selected row
                            with the accent and forces white text, unreadable on
                            Schwefel yellow. Arrow keys re-added via
                            `.onMoveCommand`. Rename sheet. Gear → `openSettings()`
                            in the footer.
    RecordingView.swift     The recording sheet: calendar banner, kind picker,
                            title, system-audio + video toggles, `WindowPickerGrid`
                            (Discord-style thumbnail tiles), auto-detect badge,
                            live preview, ⌘M marker.
    RecordingController.swift  Shared begin/finish/cancel for sheet + menu bar.
                            markers, previewFrame, recordingVideo. `importFile()`
                            brings an existing audio/video file in (video kept as
                            the session's video track too). `settings` set by the
                            app so begin() reads micDeviceID + speakerCount.
    ImportView.swift        NSOpenPanel + kind/title/speaker-count sheet.
    RecordingOptions.swift  MicPicker + SpeakerCountPicker, shared across the
                            recording sheet, menu bar and import sheet.
    MenuBarView.swift       Quick capture + pending-meeting banner + recent list.
    SessionDetailView.swift  Video pane (fullscreen, drag-resize, size + delete),
                            marker chips, PlaybackBar + `Scrubber` (system shape +
                            marker ticks a plain Slider can't draw), tabs
                            (Protokoll / Transkript), `TranscriptView`
                            (follow-scroll + "Zur aktuellen Stelle"), `SpeakerNames`
                            (with a voice menu), `MarkdownText` (tiny renderer),
                            toolbar actions (copy, export, re-transcribe, Finder).
                            Keyboard: space play/pause, ←/→ ±10s, shift ±30s — but
                            returns `.ignored` when a text field has first
                            responder (the spacebar-eats-space bug fix).
    SettingsView.swift      Darstellung (colorway grid = mini window previews +
                            Erscheinung), Sprache (Oberfläche + Gesprochene
                            Sprache), Server (URL + token + test), Kalender,
                            Protokoll-Modell (from GET /models, "Automatisch
                            (effective)"), Gespeicherte Stimmen (… menu: pop
                            sample / delete).
```

### Voice library (client side)

`SpeakerNames` per-row `person.wave.2` menu — assign a saved voice, or "Als
Stimme merken: <typed name>". `Transcriber.rememberVoice` POSTs the job's
`embeddings.json[speaker]` to `/voices`. `job.auto_speakers` (from
`voice_lib.match` server-side) pre-fills `speakerNames` if empty.

### Design history — READ THIS before touching the look

The identity went through three rounds:

1. **Six directions** → user picked **Richtung C ("Merkzettel")** — brutalist,
   hard edges, one signal colour.
2. Built it fully boxy: replaced `NavigationSplitView`, the system toolbar,
   `.searchable`, the Slider, and the title bar with hand-built square versions.
   **This cost too much** — lost the collapsible sidebar, toolbar placement
   broke, the record button got clipped by the transparent titlebar, macOS 26
   re-wrapped the toolbar buttons in a glass group. The user's words: it looked
   like "2 designs vermischt".
3. **Reverted to a native macOS 26 (Liquid Glass) shell.** `NavigationSplitView`
   + system toolbar + `.searchable` restored. `WindowPainter`, `BoxIcon`,
   `BoxSearchField`, the box scrubber — all deleted. **Kept**: the six colorways,
   the brand mark, the uppercase minutes sub-headings, Schwefel as the accent.

The lesson, and the standing rule: **the identity lives in colour, type and the
brand mark — not in fighting AppKit.** New UI extends the native vocabulary. The
one place still hand-drawn is the sidebar selection (unreadable otherwise) and
the scrubber (marker ticks).

### The brand mark

`Views/BrandMark.swift` — a "tonspur cut through at the marked spot": two paper
bars + one accent bar on a dark rounded tile, drawn in SwiftUI so it recolours
with the colorway. Also the app icon (`Resources/Assets.xcassets/AppIcon.appiconset/`,
10 PNGs generated by a one-off AppKit script — **always Schwefel**, a bundle icon
can't follow the runtime colorway).

### Typography

`Brand.display/label/body/mono` currently map to **SF Pro** (weights only). The
design calls for **Archivo / Archivo Black** but: (a) Google Fonts is unreachable
from the build machine, (b) a webfont for the whole UI looks cheap on macOS. To
adopt Archivo later: bundle the `.ttf`, change the four `Brand` functions, done.

### i18n

German keys = the strings themselves (`"Aufnehmen" = "Record";` in `en.lproj`).
So the code needed almost no changes — only ternary / `String`-typed labels get
`LocalizedStringKey(...)` wrapped. Not localized, by design: the macOS app menu
(needs the bundle language + a restart), system dialogs, runtime/Python error
strings, the model-written minutes. `Themed` injects `\.locale` so the switch is
live, no restart.

## 5. Known issues / open work

- **`VideoPlayer` crashed under Rosetta** (fixed 2026-09-03). The Mac Pro is
  Intel, so `xcodebuild` produced an x86_64-only app; on an Apple-Silicon Mac it
  ran translated, and SwiftUI's `VideoPlayer` (`_AVKit_SwiftUI`) fatal-errors in
  generic-metadata setup under Rosetta on macOS 26. Two fixes applied: (a)
  `release.sh` now builds universal (`ARCHS="arm64 x86_64"`), (b) `VideoPlayer`
  replaced with `PlayerView`, an `NSViewRepresentable` around AppKit's
  `AVPlayerView` — no `_AVKit_SwiftUI` dependency at all. **Always build the
  release universal** — the build machine is Intel, most targets are not.
- **Code signing.** The Xcode account is in a bad state ("No Account for Team
  848Y9PHXTS"). `project.yml` is plain `CODE_SIGN_STYLE: Automatic`, no team.
  **Consequence: the Screen Recording grant resets on every rebuild** — the user
  must re-allow + restart the app each time. Fix: user removes+re-adds the Apple
  ID in Xcode → Settings → Accounts, picks the Personal Team in Signing &
  Capabilities, then `grep DEVELOPMENT_TEAM mac-app/Afterword.xcodeproj/project.pbxproj`
  and gives you the real id for `project.yml`.
- **Bundle-id change did reset all TCC grants** (mic, screen recording, calendar)
  — expected, one-time, after the MeetingScribe→Afterword rename.
- **Diarisation of two people on one mic** (no system audio, same room, short
  clip) can still collapse to one speaker even with per-word assignment. Meetings
  now default to `min_speakers=2`. Best mitigation: the user sets "Sprecher: N"
  before
  recording / on import, or on a finished session via "Falsche Sprecherzahl?" →
  re-transcribe. There is no post-hoc split without re-running the pipeline.
- **Multi-speaker voice matching** — `match_threshold` (0.62) is a guess. Needs
  tuning after the user enrols a few real voices. Multi-speaker diarization
  itself is confirmed working (a real 2-person call separated correctly).
- **iPhone app** — not started. Scoped as a thin client: voice notes + browse
  server jobs. Meetings stay Mac-only (ScreenCaptureKit).
- **Archivo font** — not bundled (see Typography).
- Ideas offered, not built: video auto-cleanup by age, semantic transcript search
  via Ollama embeddings, per-person to-do rollup across meetings.
- **Studio deploy after this rename** — the first `./deploy.sh` will boot out the
  old `com.meetingscribe.server` agent (the script does it). Until that runs, the
  old agent is still serving on 8756.

## 6. Conventions

- **UI and user-facing docs: German.** Code comments: mostly English (match the
  file you're in).
- **Commits: no `Co-Authored-By: Claude` trailer** — the user asked for this
  explicitly. The repo is a single clean commit, author
  `TroyAbed <t.abed@protonmail.com>`. Not yet pushed — the user has GitHub
  Desktop and will publish `Afterword` as a private repo.
- `deploy.sh` asks for the Studio password; there is no key. Don't add one.
- Don't touch the brother's `ollama.network.plist` on the Studio.
- `git`-ignored and never committed: `*.xcodeproj/`, venvs, `token.txt`,
  `speakers.json`, `voices/`, `data/`, `inbox/`, `output/`,
  `design/afterword-identitaet.html` (the seeded canvas — source is the
  `.dc.html` files + `canvas.json`).

## 7. Re-seeding / updating the design canvas

The 4 boards live in `design/`. To change them: edit the `.dc.html` files, then
re-run the Claude Design skill's `seed-canvas.mjs` with `--out
afterword-identitaet.html --title Afterword` and the 4 `--artboard` flags +
`--canvas canvas.json`, and republish to the existing artifact URL
(`https://claude.ai/code/artifact/7ddbc5bb-b1e0-4a2c-ba83-96a4c9a8b675`).
