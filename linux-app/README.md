# Afterword — Linux client

A PySide6 (Qt 6) desktop client for the Afterword server (`../server.py`). Record
a meeting or a voice note, or import a file; it goes to the server on the Mac
Studio and comes back as a speaker-separated transcript + German minutes.

Same server, same API as the macOS app. What the macOS app has and this does
**not** (yet): window-video recording, calendar auto-record, a menu-bar tray,
the colorways.

## Run it (CachyOS / Arch)

Quickest — install as a package:

```bash
cd linux-app
makepkg -si            # pulls python-pyside6, ffmpeg, libpulse from the repos
afterword              # or launch it from the app menu
```

Or run from source without installing:

```bash
cd linux-app
./run.sh               # makes a .venv with PySide6 on first run if needed
```

System packages if you prefer: `sudo pacman -S python-pyside6 ffmpeg`.

## First launch

- **Einstellungen (Ctrl+,)** → Server-URL: `http://maxpi:8756` (or the Studio's
  address), test the connection. Leave the token empty unless the server has
  `app/token.txt`.
- Pick your **Mikrofon** and, for meetings, the **Systemton** source — that is
  usually the `.monitor` of your default output (needs `pipewire-pulse`).
- **Ollama-Server** stays empty — the Studio uses its own.

## How recording works

Recording uses `ffmpeg -f pulse` — one process for the mic, one for the monitor
source. The two tracks are uploaded separately and mixed on the server, exactly
like the macOS client. Playback mixes them locally once into `mixed.m4a`.

Sessions live in `~/.local/share/afterword/sessions/`, config in
`~/.config/afterword/config.json`.
