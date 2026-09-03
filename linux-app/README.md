# Afterword — Linux client

A PySide6 (Qt 6) desktop client for the Afterword server (`../server.py`). Record
a meeting or a voice note, or import a file; it goes to the server on the Mac
Studio and comes back as a speaker-separated transcript + German minutes.

Same server, same API as the macOS app. What the macOS app has and this does
**not** (yet): window-video recording, calendar auto-record, a menu-bar tray, the
colorways.

---

## What you need

- **CachyOS / Arch / any Arch derivative** (other distros work too — see *Other
  distros* below)
- A running Afterword server reachable from this machine (default
  `http://maxpi:8756`)
- These packages (the PKGBUILD pulls them automatically):
  - `python` ≥ 3.10
  - `python-pyside6` — the Qt 6 bindings
  - `ffmpeg` — recording and audio mixing
  - `libpulse` / `pipewire-pulse` — so `ffmpeg -f pulse` and `pactl` work
    (CachyOS ships PipeWire with the Pulse shim by default)

---

## Build & install (recommended)

```bash
git clone https://github.com/TroyAbed/Afterword.git
cd Afterword/linux-app
makepkg -si
```

`makepkg -si` does three things:

1. reads `PKGBUILD`, resolves and installs the dependencies above,
2. packages `afterword/` into `/usr/share/afterword/` with a launcher at
   `/usr/bin/afterword` and a desktop entry,
3. installs that package with `pacman`.

Then start it:

```bash
afterword
```

…or find **Afterword** in the application menu (Audio/Video section).

### Rebuild after a `git pull`

```bash
cd Afterword && git pull
cd linux-app
makepkg -si          # reinstalls the current tree
```

If `makepkg` refuses because the version didn't change, force it: `makepkg -sif`.

### Uninstall

```bash
sudo pacman -R afterword
```

Recordings in `~/.local/share/afterword/` and config in `~/.config/afterword/`
are left in place — delete them by hand if you want them gone.

---

## Run from source (no install)

Good for trying it or hacking on it:

```bash
cd Afterword/linux-app
./run.sh
```

`run.sh` uses the system `python-pyside6` if it's installed; otherwise it creates
a local `.venv/` and `pip install`s PySide6 into it on first run. Either way it
then runs `python -m afterword`.

You still need `ffmpeg` and `pactl` on `PATH`:

```bash
sudo pacman -S ffmpeg libpulse
```

---

## Manual venv (fully self-contained)

```bash
cd Afterword/linux-app
python -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m afterword
```

---

## Other distros

- **Fedora:** `sudo dnf install python3-pyside6 ffmpeg pulseaudio-utils`, then
  run from source (`./run.sh` or the manual venv).
- **Debian/Ubuntu:** `sudo apt install python3-pyside6.qtwidgets
  python3-pyside6.qtmultimedia ffmpeg pulseaudio-utils` (or `pip install PySide6`
  in a venv), then run from source.
- Anything else: a venv with `pip install PySide6`, plus `ffmpeg` and `pactl`
  from the distro.

The `PKGBUILD` is Arch-only; everything else uses `run.sh` / the venv.

---

## First launch

1. **Einstellungen** (Ctrl+,)
   - **Server-URL:** `http://maxpi:8756` (or the Studio's address). Hit
     **Verbindung testen** — it should say *erreichbar*.
   - **Token:** leave empty unless the server has `app/token.txt`.
   - **Mikrofon:** your input device.
   - **Systemton:** the `.monitor` of your default output ("what you hear"). The
     list is prefilled with a sensible default; needs `pipewire-pulse`.
   - **Ollama-Server:** leave **empty** — the Studio uses its own Ollama.
   - **Namen & Begriffe:** recurring names / tech terms, so the transcript spells
     them right.
2. **Aufnehmen** or **Importieren** from the toolbar.

---

## Where things live

| | |
|---|---|
| Config | `~/.config/afterword/config.json` |
| Recordings + transcripts | `~/.local/share/afterword/sessions/<uuid>/` |
| Installed code (pkg) | `/usr/share/afterword/` |
| Launcher (pkg) | `/usr/bin/afterword` |

Each session folder has `meta.json`, `audio.m4a`, optionally `system.m4a` and a
`mixed.m4a` (built on first playback).

---

## How recording works

`ffmpeg -f pulse -i <source>` — one process for the mic, one for the monitor
source. The two tracks upload separately and the **server** mixes them, exactly
like the macOS client. Playback mixes them locally once into `mixed.m4a`.

---

## Troubleshooting

Run it from a terminal (`./run.sh`, or `afterword` if installed) so you see
errors.

**"ffmpeg fehlt"** — `sudo pacman -S ffmpeg`.

**The mic / system-audio dropdowns are empty or wrong** — the app parses
`pactl list sources`. Check it returns something:
```bash
pactl list sources short
```
If empty, PipeWire's Pulse shim isn't running: `systemctl --user status
pipewire-pulse`.

**No sound on playback / "Unsupported media type"** — Qt Multimedia needs a
backend. On Arch, `python-pyside6` pulls `qt6-multimedia`; make sure the FFmpeg
backend is present. As a check:
```bash
QT_MEDIA_BACKEND=ffmpeg afterword
```

**"nicht erreichbar" on the connection test** — same checklist as the macOS app:
Tailscale connected on this machine? Pi up? Studio awake?
`curl http://maxpi:8756/health`.

**"<urlopen error … nodename nor servername …>" in a failed summary** — a bad
value in **Ollama-Server**. Clear that field.

**A recording stays "Wird transkribiert …" forever** — the app re-tries a stuck
job every few seconds and picks up when the server is back. If it never does,
right-click the session → *Erneut transkribieren*.

When you hit something not listed here, paste the terminal traceback.
