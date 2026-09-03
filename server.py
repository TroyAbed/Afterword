#!/usr/bin/env python3
"""HTTP service for the Swift app — upload audio, poll for transcript + summary.

    uvicorn server:app --host 0.0.0.0 --port 8756

Endpoints (all need `Authorization: Bearer <token>` if app/token.txt exists):
  POST /jobs            multipart: audio=<file> kind=meeting|voicenote
                        title=... language=... speakers={"SPEAKER_00":"Thomas"}
                        -> job meta {id, status: "queued", ...}
  GET  /jobs            list all jobs, newest first
  GET  /jobs/{id}       job meta + transcript_md + summary_md (when done)
  GET  /jobs/{id}/audio original upload
  GET  /health

Jobs run one at a time in a background thread (whisperx is heavy). State lives in
~/whisper-service/data/<id>/  (audio + transcript.md + summary.md + meta.json).
"""
from __future__ import annotations

import json
import secrets
import shutil
import threading
import traceback
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from queue import Queue

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse

import pipeline
import voices as voice_lib

ROOT = Path(__file__).resolve().parent
CFG = pipeline.load_config()
DATA = ROOT.parent / "data"                       # ~/whisper-service/data
DATA.mkdir(exist_ok=True)
TOKEN = (ROOT / "token.txt").read_text().strip() if (ROOT / "token.txt").exists() else None

app = FastAPI(title="afterword")
_queue: "Queue[str]" = Queue()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def auth(authorization: str | None = Header(None)) -> None:
    if TOKEN and authorization != f"Bearer {TOKEN}":
        raise HTTPException(401, "missing or bad bearer token")


def _dir(jid: str) -> Path:
    return DATA / jid


def _meta(jid: str) -> dict:
    return json.loads((_dir(jid) / "meta.json").read_text())


def _save_meta(jid: str, m: dict) -> None:
    (_dir(jid) / "meta.json").write_text(json.dumps(m, indent=2, ensure_ascii=False))


@app.get("/health")
async def health() -> dict:
    return {"ok": True, "queued": _queue.qsize()}


@app.get("/models", dependencies=[Depends(auth)])
async def models(ollama_url: str = "") -> dict:
    """Ollama models + which one "Automatic" resolves to now.
    Pass ?ollama_url= to inspect a different Ollama than the server's own."""
    base = (ollama_url or CFG["summary"]["ollama_url"]).rstrip("/")
    try:
        raw = urllib.request.urlopen(base + "/api/tags", timeout=10).read()
        avail = sorted(m["name"] for m in json.loads(raw).get("models", []))
    except Exception:  # noqa: BLE001
        avail = []
    want = CFG["summary"]["ollama_model"]
    prefs = CFG["summary"].get("fallback_models", []) + avail
    effective = want if want in avail else next((m for m in prefs if m in avail), "")
    return {"available": avail, "effective": effective}


@app.post("/jobs", dependencies=[Depends(auth)])
async def create_job(
    audio: UploadFile,
    kind: str = Form("meeting"),
    title: str = Form(""),
    language: str = Form(""),
    speakers: str = Form("{}"),
    summary_model: str = Form(""),
    ollama_url: str = Form(""),
    speaker_count: int = Form(0),          # 0 = let pyannote decide
    vocab: str = Form(""),                 # names / terms to bias the ASR toward
    system_audio: UploadFile | None = File(None),
) -> dict:
    jid = datetime.now().strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(3)
    d = _dir(jid)
    d.mkdir(parents=True)

    ext = Path(audio.filename or "audio.m4a").suffix.lower() or ".m4a"
    apath = d / f"audio{ext}"
    with apath.open("wb") as f:
        shutil.copyfileobj(audio.file, f)

    spath = None
    if system_audio is not None:
        sext = Path(system_audio.filename or "system.m4a").suffix.lower() or ".m4a"
        spath = d / f"system{sext}"
        with spath.open("wb") as f:
            shutil.copyfileobj(system_audio.file, f)

    m = {
        "id": jid, "kind": kind, "title": title or jid,
        "language": language, "speakers": json.loads(speakers or "{}"),
        "summary_model": summary_model or None,
        "ollama_url": ollama_url or None,
        "speaker_count": speaker_count or None,
        "vocab": vocab or None,
        "audio": apath.name, "system_audio": spath.name if spath else None,
        "status": "queued", "created_at": _now(),
    }
    _save_meta(jid, m)
    _queue.put(jid)
    return m


@app.get("/jobs", dependencies=[Depends(auth)])
async def list_jobs() -> list[dict]:
    out = []
    for d in sorted(DATA.iterdir(), reverse=True):
        if (d / "meta.json").exists():
            out.append(json.loads((d / "meta.json").read_text()))
    return out


@app.get("/jobs/{jid}", dependencies=[Depends(auth)])
async def get_job(jid: str) -> dict:
    if not (_dir(jid) / "meta.json").exists():
        raise HTTPException(404, "no such job")
    m = _meta(jid)
    for key, fn in (("transcript_md", "transcript.md"), ("summary_md", "summary.md")):
        p = _dir(jid) / fn
        m[key] = p.read_text() if p.exists() else None
    seg = _dir(jid) / "segments.json"
    m["segments"] = json.loads(seg.read_text()) if seg.exists() else None
    m.setdefault("auto_speakers", None)
    return m


@app.post("/jobs/{jid}/resummarize", dependencies=[Depends(auth)])
async def resummarize(jid: str, speakers: str = Form("{}"),
                      summary_model: str = Form(""),
                      ollama_url: str = Form("")) -> dict:
    """Regenerate the summary (used after labelling speakers or a failed run)."""
    import asyncio
    d = _dir(jid)
    tpath = d / "transcript.md"
    if not tpath.exists():
        raise HTTPException(404, "no transcript yet")
    text = tpath.read_text()
    for tag, name in json.loads(speakers or "{}").items():
        if name.strip():
            text = text.replace(f"**{tag}**", f"**{name}**")
    cfg = json.loads(json.dumps(CFG))
    if summary_model:
        cfg["summary"]["ollama_model"] = summary_model
    if ollama_url:
        cfg["summary"]["ollama_url"] = ollama_url
    summary = await asyncio.to_thread(pipeline.summarize, text, cfg)
    (d / "summary.md").write_text(summary)
    m = _meta(jid)
    m["resummarized_at"] = _now()
    _save_meta(jid, m)
    return {"summary_md": summary}


@app.get("/jobs/{jid}/audio", dependencies=[Depends(auth)])
async def get_audio(jid: str) -> FileResponse:
    if not (_dir(jid) / "meta.json").exists():
        raise HTTPException(404, "no such job")
    return FileResponse(_dir(jid) / _meta(jid)["audio"])


# ---- voice library -------------------------------------------------------

@app.get("/voices", dependencies=[Depends(auth)])
async def list_voices() -> list[dict]:
    return voice_lib.names()


@app.post("/voices", dependencies=[Depends(auth)])
async def add_voice(name: str = Form(...), job_id: str = Form(...),
                    speaker: str = Form(...)) -> dict:
    """Save the voice of `speaker` (e.g. SPEAKER_00) from job `job_id` under `name`."""
    ep = _dir(job_id) / "embeddings.json"
    if not ep.exists():
        raise HTTPException(404, "job has no voice embeddings")
    emb = json.loads(ep.read_text())
    if speaker not in emb:
        raise HTTPException(404, f"no embedding for {speaker} in that job")
    voice_lib.add_sample(name.strip(), emb[speaker])
    return {"ok": True, "voices": voice_lib.names()}


@app.delete("/voices/{name}", dependencies=[Depends(auth)])
async def delete_voice(name: str) -> dict:
    voice_lib.remove(name)
    return {"ok": True, "voices": voice_lib.names()}


@app.post("/voices/{name}/pop", dependencies=[Depends(auth)])
async def pop_voice_sample(name: str) -> dict:
    voice_lib.pop_last(name)
    return {"ok": True, "voices": voice_lib.names()}


def _worker() -> None:
    while True:
        jid = _queue.get()
        d = _dir(jid)
        try:
            m = _meta(jid)
            m.update(status="running", started_at=_now())
            _save_meta(jid, m)

            cfg = json.loads(json.dumps(CFG))            # deep copy
            if m.get("language"):
                cfg["transcribe"]["language"] = m["language"]
            if m.get("summary_model"):
                cfg["summary"]["ollama_model"] = m["summary_model"]
            if m.get("ollama_url"):
                cfg["summary"]["ollama_url"] = m["ollama_url"]
            if m.get("speaker_count"):
                cfg["transcribe"]["min_speakers"] = m["speaker_count"]
                cfg["transcribe"]["max_speakers"] = m["speaker_count"]
            if m.get("vocab"):
                base = cfg["transcribe"].get("initial_prompt", "")
                cfg["transcribe"]["initial_prompt"] = (
                    base + " Namen und Begriffe: " + m["vocab"] + ".").strip()

            secondary = d / m["system_audio"] if m.get("system_audio") else None

            # phase 1 — transcript + diarisation (fast); publish immediately
            res = pipeline.transcribe_and_diarize(
                d / m["audio"], d, cfg,
                names=m.get("speakers") or {}, secondary_audio=secondary)
            (d / "transcript.md").write_text(res["transcript_md"])
            slim = [{"start": s.get("start"), "end": s.get("end"),
                     "text": (s.get("text") or "").strip(), "speaker": s.get("speaker")}
                    for s in res["segments"] if (s.get("text") or "").strip()]
            (d / "segments.json").write_text(json.dumps(slim, ensure_ascii=False))

            emb = res.get("embeddings") or {}
            (d / "embeddings.json").write_text(json.dumps(emb))
            thr = CFG.get("voices", {}).get("match_threshold", 0.62)
            auto = voice_lib.match(emb, thr) if emb else {}

            m.update(status="transcribed", transcribed_at=_now(),
                     speakers_detected=res["speakers"],
                     auto_speakers=auto or None,
                     detected_language=res["language"])
            _save_meta(jid, m)

            # phase 2 — Ollama summary
            summary = pipeline.summarize(res["transcript_md"], cfg)
            (d / "summary.md").write_text(summary)
            m.update(status="done", finished_at=_now())
        except Exception as e:  # noqa: BLE001
            m = _meta(jid)
            m.update(status="error", error=str(e),
                     traceback=traceback.format_exc(), finished_at=_now())
        _save_meta(jid, m)
        _queue.task_done()


threading.Thread(target=_worker, daemon=True).start()

# on restart, re-queue anything that was mid-flight
for _d in sorted(DATA.iterdir()):
    _mp = _d / "meta.json"
    if _mp.exists() and json.loads(_mp.read_text()).get("status") in ("queued", "running"):
        _queue.put(_d.name)
