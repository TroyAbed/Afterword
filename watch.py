#!/usr/bin/env python3
"""Watch inbox/ for new audio files, run scribe.py on each, move to processed/.

    python watch.py

Drop a recording into ~/whisper-service/app/inbox/ (or scp it there) and the
transcript + summary land in output/. Speaker names come from speakers.json if
present. Ctrl-C to stop.
"""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
INBOX, DONE, OUT = ROOT / "inbox", ROOT / "processed", ROOT / "output"
AUDIO_EXT = {".wav", ".mp3", ".m4a", ".mp4", ".aac", ".flac", ".ogg", ".webm", ".opus"}
POLL_S = 5


def stable(f: Path) -> bool:
    """True once the file has stopped growing (copy finished)."""
    a = f.stat().st_size
    time.sleep(2)
    return f.exists() and f.stat().st_size == a


def main() -> None:
    for d in (INBOX, DONE, OUT):
        d.mkdir(exist_ok=True)
    print(f"watching {INBOX}  (Ctrl-C zum Beenden)")
    while True:
        for f in sorted(INBOX.iterdir()):
            if f.suffix.lower() not in AUDIO_EXT or not stable(f):
                continue
            print(f"\n=== {f.name} ===")
            cmd = [sys.executable, str(ROOT / "scribe.py"), str(f), "--outdir", str(OUT)]
            sp = ROOT / "speakers.json"
            if sp.exists():
                cmd += ["--speakers", str(sp)]
            try:
                subprocess.run(cmd, check=True)
                f.rename(DONE / f.name)
                print(f"    fertig -> {OUT}")
            except subprocess.CalledProcessError as e:
                print(f"    !! Fehler ({e.returncode}); Datei bleibt im inbox/")
        time.sleep(POLL_S)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\ngestoppt")
