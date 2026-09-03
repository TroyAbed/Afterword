"""Non-UI core for the Linux client: config, the Session model, the local
library, and the HTTP client for server.py. No Qt in here."""
from __future__ import annotations

import json
import mimetypes
import os
import re
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from urllib import request as urlrequest
from urllib.error import HTTPError, URLError

APP = "afterword"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / APP
DATA_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / APP
SESSIONS = DATA_DIR / "sessions"


# --------------------------------------------------------------------------- config

_DEFAULTS = {
    "server_url": "http://maxpi:8756",
    "token": "",
    "language": "de",          # de | en | "" (auto)
    "summary_model": "",        # "" = server default
    "ollama_url": "",           # "" = server's own Ollama
    "vocabulary": "",           # names / terms, comma or newline separated
    "speaker_count": 0,         # 0 = automatic
    "mic_source": "",           # pulse source name, "" = default
    "system_source": "",        # pulse monitor source name, "" = none
}


class Config:
    def __init__(self) -> None:
        self.path = CONFIG_DIR / "config.json"
        self._d = dict(_DEFAULTS)
        if self.path.exists():
            try:
                self._d.update(json.loads(self.path.read_text()))
            except Exception:
                pass

    def __getitem__(self, k): return self._d.get(k, _DEFAULTS.get(k))
    def __setitem__(self, k, v):
        self._d[k] = v
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self._d, indent=2))

    @property
    def ollama_override(self) -> str:
        raw = str(self._d.get("ollama_url", "")).strip()
        m = re.match(r"^https?://[^/\s]+", raw)
        return raw if m else ""

    def vocab_hint(self, voice_names: list[str]) -> str:
        parts = re.split(r"[,;\n]", self._d.get("vocabulary", ""))
        parts += voice_names
        seen = sorted({p.strip() for p in parts if p.strip()})
        return ", ".join(seen)


# --------------------------------------------------------------------------- model

STATUS_BUSY = {"uploading", "queued", "running", "processing", "transcribed"}


@dataclass
class Segment:
    start: float | None
    end: float | None
    text: str
    speaker: str | None

    @property
    def start_time(self) -> float:
        return self.start or 0.0


@dataclass
class Session:
    id: str
    kind: str = "meeting"                 # meeting | voicenote
    title: str = ""
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    duration: float | None = None
    status: str = "uploading"
    has_system_audio: bool = False
    speaker_count: int = 0
    markers: list[float] = field(default_factory=list)
    server_job_id: str | None = None
    transcript_md: str | None = None
    summary_md: str | None = None
    segments: list[Segment] = field(default_factory=list)
    speakers: list[str] = field(default_factory=list)
    speaker_names: dict[str, str] = field(default_factory=dict)
    language: str | None = None
    error: str | None = None

    # ------- persistence

    @classmethod
    def new(cls, kind: str, title: str = "") -> "Session":
        return cls(id=str(uuid.uuid4()), kind=kind, title=title, status="recording")

    @classmethod
    def load(cls, d: Path) -> "Session | None":
        p = d / "meta.json"
        if not p.exists():
            return None
        try:
            raw = json.loads(p.read_text())
        except Exception:
            return None
        raw["segments"] = [Segment(**s) for s in raw.get("segments", [])]
        known = {f for f in cls.__dataclass_fields__}
        return cls(**{k: v for k, v in raw.items() if k in known})

    def save(self) -> None:
        d = SESSIONS / self.id
        d.mkdir(parents=True, exist_ok=True)
        raw = {k: getattr(self, k) for k in self.__dataclass_fields__}
        raw["segments"] = [vars(s) for s in self.segments]
        (d / "meta.json").write_text(json.dumps(raw, indent=2, ensure_ascii=False))

    # ------- paths

    @property
    def dir(self) -> Path: return SESSIONS / self.id
    @property
    def audio_path(self) -> Path: return self.dir / "audio.m4a"
    @property
    def system_path(self) -> Path: return self.dir / "system.m4a"

    # ------- display

    @property
    def display_title(self) -> str:
        if self.title.strip():
            return self.title
        try:
            return datetime.fromisoformat(self.created_at).astimezone().strftime("%d.%m.%Y %H:%M")
        except Exception:
            return self.id[:8]

    def speaker_label(self, tag: str | None) -> str:
        if not tag:
            return "Unbekannt"
        return self.speaker_names.get(tag) or tag

    def _apply_names(self, text: str) -> str:
        for tag, name in self.speaker_names.items():
            if name:
                text = text.replace(f"**{tag}**", f"**{name}**").replace(tag, name)
        for i in range(12):
            tag = f"SPEAKER_{i:02d}"
            if tag in text:
                text = text.replace(tag, f"Sprecher {i + 1}")
        return text

    @property
    def rendered_transcript(self) -> str: return self._apply_names(self.transcript_md or "")
    @property
    def rendered_summary(self) -> str: return self._apply_names(self.summary_md or "")

    @property
    def speaker_groups(self) -> list[tuple[str | None, list[Segment]]]:
        groups: list[tuple[str | None, list[Segment]]] = []
        for seg in self.segments:
            if groups and groups[-1][0] == seg.speaker:
                groups[-1][1].append(seg)
            else:
                groups.append((seg.speaker, [seg]))
        return groups


def load_session(sid: str) -> "Session | None":
    return Session.load(SESSIONS / sid)


def all_sessions() -> list[Session]:
    SESSIONS.mkdir(parents=True, exist_ok=True)
    out = []
    for d in SESSIONS.iterdir():
        if d.is_dir():
            s = Session.load(d)
            if s:
                out.append(s)
    out.sort(key=lambda s: s.created_at, reverse=True)
    return out


def delete_session(s: Session) -> None:
    import shutil
    shutil.rmtree(s.dir, ignore_errors=True)


# --------------------------------------------------------------------------- API

class ApiError(Exception):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class ScribeAPI:
    def __init__(self, base: str, token: str = ""):
        self.base = str(base).rstrip("/")
        self.token = str(token or "")

    @classmethod
    def from_config(cls, cfg: "Config") -> "ScribeAPI":
        return cls(str(cfg["server_url"]), str(cfg["token"]))

    def _headers(self, extra: dict | None = None) -> dict:
        h = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        h.update(extra or {})
        return h

    def _get(self, path: str) -> dict | list:
        req = urlrequest.Request(self.base + path, headers=self._headers())
        try:
            with urlrequest.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        except HTTPError as e:
            raise ApiError(f"HTTP {e.code}", e.code)
        except URLError as e:
            raise ApiError(str(e.reason))

    def health(self) -> bool:
        try:
            urlrequest.urlopen(self.base + "/health", timeout=8)
            return True
        except Exception:
            return False

    def models(self, ollama_url: str = "") -> dict:
        q = f"?ollama_url={urlrequest.quote(ollama_url)}" if ollama_url else ""
        return self._get("/models" + q)  # {available, effective}

    def jobs(self) -> list:
        return self._get("/jobs")

    def job(self, jid: str) -> dict:
        return self._get(f"/jobs/{jid}")

    def submit(self, *, audio: Path, system_audio: Path | None, kind: str, title: str,
               language: str, summary_model: str, ollama_url: str,
               speaker_count: int, vocab: str) -> dict:
        fields = {
            "kind": "meeting" if kind == "meeting" else "voicenote",
            "title": title, "language": language,
            "summary_model": summary_model, "ollama_url": ollama_url,
            "speaker_count": str(speaker_count), "vocab": vocab,
        }
        files = [("audio", audio)]
        if system_audio and system_audio.exists():
            files.append(("system_audio", system_audio))
        body, ctype = _multipart(fields, files)
        req = urlrequest.Request(self.base + "/jobs", data=body, method="POST",
                                 headers=self._headers({"Content-Type": ctype}))
        try:
            with urlrequest.urlopen(req, timeout=600) as r:
                return json.loads(r.read())
        except HTTPError as e:
            raise ApiError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:200]}", e.code)
        except URLError as e:
            raise ApiError(str(e.reason))

    def resummarize(self, jid: str, speakers: dict, summary_model: str, ollama_url: str) -> str:
        fields = {"speakers": json.dumps(speakers), "summary_model": summary_model,
                  "ollama_url": ollama_url}
        body, ctype = _multipart(fields, [])
        req = urlrequest.Request(self.base + f"/jobs/{jid}/resummarize", data=body,
                                 method="POST", headers=self._headers({"Content-Type": ctype}))
        try:
            with urlrequest.urlopen(req, timeout=600) as r:
                return json.loads(r.read()).get("summary_md", "")
        except HTTPError as e:
            raise ApiError(f"HTTP {e.code}", e.code)
        except URLError as e:
            raise ApiError(str(e.reason))

    def voices(self) -> list:
        try:
            return self._get("/voices")
        except ApiError:
            return []

    def save_voice(self, name: str, job_id: str, speaker: str) -> None:
        body, ctype = _multipart({"name": name, "job_id": job_id, "speaker": speaker}, [])
        req = urlrequest.Request(self.base + "/voices", data=body, method="POST",
                                 headers=self._headers({"Content-Type": ctype}))
        urlrequest.urlopen(req, timeout=30)


def _multipart(fields: dict, files: list[tuple[str, Path]]) -> tuple[bytes, str]:
    boundary = "----afterword" + uuid.uuid4().hex
    parts: list[bytes] = []
    for k, v in fields.items():
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    for name, path in files:
        ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; '
            f'filename="{path.name}"\r\nContent-Type: {ctype}\r\n\r\n'.encode())
        parts.append(path.read_bytes())
        parts.append(b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"
