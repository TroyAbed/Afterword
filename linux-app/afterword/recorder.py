"""Audio recording on Linux via ffmpeg + PipeWire's PulseAudio interface.

Mic and (optionally) a monitor source are captured to two separate .m4a files,
mirroring the macOS client — the server mixes them.
"""
from __future__ import annotations

import shutil
import subprocess
import time
from pathlib import Path


def have_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


def sources() -> list[tuple[str, str, bool]]:
    """(name, description, is_monitor) for every PulseAudio/PipeWire source."""
    try:
        out = subprocess.check_output(["pactl", "list", "sources"], text=True,
                                      stderr=subprocess.DEVNULL)
    except Exception:
        return []
    items: list[tuple[str, str, bool]] = []
    name = desc = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("Name: "):
            name = line[6:]
        elif line.startswith("Description: "):
            desc = line[13:]
        if name and desc:
            items.append((name, desc, ".monitor" in name))
            name = desc = None
    return items


def default_monitor() -> str:
    """The monitor of the default sink — i.e. 'what you hear'."""
    try:
        sink = subprocess.check_output(["pactl", "get-default-sink"], text=True,
                                       stderr=subprocess.DEVNULL).strip()
        return f"{sink}.monitor" if sink else ""
    except Exception:
        return ""


class Recorder:
    """Runs one or two ffmpeg processes for the length of a recording."""

    def __init__(self) -> None:
        self._procs: list[subprocess.Popen] = []
        self._started: float | None = None
        self.captured_system = False

    @property
    def is_recording(self) -> bool:
        return self._started is not None

    @property
    def elapsed(self) -> float:
        return 0.0 if self._started is None else time.monotonic() - self._started

    def start(self, mic_out: Path, mic_source: str,
              system_out: Path | None, system_source: str) -> None:
        mic_out.parent.mkdir(parents=True, exist_ok=True)
        for p in (mic_out, system_out):
            if p:
                p.unlink(missing_ok=True)

        self._procs = [self._ffmpeg(mic_source or "default", mic_out)]
        self.captured_system = False
        if system_out and system_source:
            try:
                self._procs.append(self._ffmpeg(system_source, system_out))
                self.captured_system = True
            except Exception:
                pass
        self._started = time.monotonic()

    @staticmethod
    def _ffmpeg(source: str, out: Path) -> subprocess.Popen:
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
               "-f", "pulse", "-i", source,
               "-ac", "1", "-c:a", "aac", "-b:a", "128k", str(out)]
        return subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def stop(self) -> float:
        elapsed = self.elapsed
        for p in self._procs:
            try:
                p.communicate(input=b"q", timeout=5)
            except Exception:
                p.terminate()
                try:
                    p.wait(timeout=3)
                except Exception:
                    p.kill()
        self._procs = []
        self._started = None
        return elapsed
