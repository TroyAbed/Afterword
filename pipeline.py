"""Core pipeline — one audio file to a diarized transcript + German summary.

Shared by scribe.py (CLI), server.py (HTTP), watch.py (folder). Runs on the Mac
Studio inside ~/whisper-service/.venv.

ASR: mlx-whisper (Metal, fast on Apple Silicon).
Diarisation: pyannote, run directly and mapped onto the ASR segments.
"""
from __future__ import annotations

import json
import os
import subprocess
import tomllib
import urllib.request
from datetime import timedelta
from pathlib import Path

# launchd / a bare shell runs uvicorn without sourcing .venv/bin/activate, so set
# the model paths + offline mode here rather than relying on the environment.
_SVC = Path.home() / "whisper-service"
os.environ.setdefault("HF_HOME", str(_SVC / "models" / "huggingface"))
os.environ.setdefault("TORCH_HOME", str(_SVC / "models" / "torch"))
os.environ.setdefault("HF_HUB_OFFLINE", "1")        # models are pre-downloaded; never call HF
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

# a non-interactive shell also has a thin PATH that misses Homebrew's ffmpeg.
for _p in ("/opt/homebrew/bin", "/usr/local/bin"):
    if _p not in os.environ.get("PATH", "").split(":") and Path(_p).is_dir():
        os.environ["PATH"] = _p + ":" + os.environ.get("PATH", "")

ROOT = Path(__file__).resolve().parent


def load_config(path: Path | None = None) -> dict:
    return tomllib.loads((path or ROOT / "config.toml").read_text())


def _hhmm(seconds: float) -> str:
    return str(timedelta(seconds=int(seconds)))


def prepare_wav(audio: Path, out: Path, secondary: Path | None = None) -> Path:
    """Produce a mono 16 kHz WAV for the ASR + diariser. If `secondary` (system
    audio) is given it is mixed in; dynaudnorm evens the usually different levels."""
    if secondary and secondary.exists():
        cmd = ["ffmpeg", "-y", "-i", str(audio), "-i", str(secondary),
               "-filter_complex",
               "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0,dynaudnorm",
               "-ac", "1", "-ar", "16000", str(out)]
    else:
        cmd = ["ffmpeg", "-y", "-i", str(audio), "-ac", "1", "-ar", "16000", str(out)]
    subprocess.run(cmd, check=True, capture_output=True)
    return out


# ---- ASR (mlx-whisper) -------------------------------------------------------

def transcribe_segments(audio: Path, cfg: dict) -> tuple[list[dict], str]:
    import mlx_whisper

    t = cfg["transcribe"]
    r = mlx_whisper.transcribe(
        str(audio),
        path_or_hf_repo=t.get("mlx_model", "mlx-community/whisper-large-v3-mlx"),
        language=t.get("language") or None,
        initial_prompt=t.get("initial_prompt") or None,
        word_timestamps=True,
        condition_on_previous_text=False,
    )
    segs = []
    for s in r.get("segments", []):
        if not s.get("text", "").strip():
            continue
        segs.append({
            "start": s["start"], "end": s["end"], "text": s["text"].strip(),
            "words": [{"start": w.get("start"), "end": w.get("end"),
                       "word": (w.get("word") or "").strip()}
                      for w in s.get("words", []) if (w.get("word") or "").strip()],
        })
    return segs, r.get("language", t.get("language") or "")


# ---- diarisation (pyannote) ------------------------------------------------

_DIARIZER = None


def _diarizer(cfg: dict):
    global _DIARIZER
    if _DIARIZER is None:
        import torch
        from pyannote.audio import Pipeline
        pipe = Pipeline.from_pretrained(
            cfg["transcribe"].get("diarize_model", "pyannote/speaker-diarization-community-1"))
        if cfg["transcribe"].get("diarize_device", "mps") == "mps" and torch.backends.mps.is_available():
            try:
                pipe.to(torch.device("mps"))
            except Exception:  # noqa: BLE001  — some pyannote ops lack MPS kernels
                pass
        _DIARIZER = pipe
    return _DIARIZER


def diarize(wav: Path, cfg: dict) -> tuple[list[tuple[float, float, str]], dict[str, list[float]]]:
    """Diarise a mono 16 kHz WAV → (speaker turns, per-speaker voice embeddings).
    Audio is fed as a waveform tensor so pyannote does not need torchcodec."""
    import numpy as np
    import soundfile as sf
    import torch

    t = cfg["transcribe"]
    kw = {}
    if t.get("min_speakers"):
        kw["min_speakers"] = int(t["min_speakers"])
    if t.get("max_speakers"):
        kw["max_speakers"] = int(t["max_speakers"])

    data, sr = sf.read(str(wav), dtype="float32", always_2d=True)   # (time, ch)
    waveform = torch.from_numpy(data.T)                             # (ch, time)
    if waveform.shape[0] > 1:
        waveform = waveform.mean(dim=0, keepdim=True)

    result = _diarizer(cfg)({"waveform": waveform, "sample_rate": sr}, **kw)
    # newer pyannote returns DiarizeOutput; legacy returns an Annotation directly
    sd = getattr(result, "speaker_diarization", None) or result
    ann = getattr(result, "exclusive_speaker_diarization", None) or sd
    turns = [(turn.start, turn.end, label)
             for turn, _, label in ann.itertracks(yield_label=True)]

    embeddings: dict[str, list[float]] = {}
    vecs = getattr(result, "speaker_embeddings", None)
    if vecs is not None and hasattr(sd, "labels"):
        for label, vec in zip(sd.labels(), vecs):
            arr = np.asarray(vec, dtype=float)
            if arr.size and not np.isnan(arr).any():
                embeddings[label] = arr.tolist()
    return turns, embeddings


def _speaker_at(t0: float, t1: float, turns: list[tuple[float, float, str]]) -> str | None:
    best, best_ov = None, 0.0
    for ts, te, label in turns:
        ov = min(t1, te) - max(t0, ts)
        if ov > best_ov:
            best_ov, best = ov, label
    return best


def assign_speakers(segments: list[dict], turns: list[tuple[float, float, str]]) -> list[dict]:
    """Assign a speaker per WORD (not per whole segment), then split each segment
    at speaker changes. Much better at turn boundaries than whole-segment
    max-overlap. Returns a new segment list; segments with no word timestamps
    fall back to the old behaviour."""
    if not turns:
        for seg in segments:
            seg["speaker"] = None
        return segments

    out: list[dict] = []
    for seg in segments:
        words = seg.get("words") or []
        if not words:
            seg["speaker"] = _speaker_at(seg["start"], seg["end"], turns)
            seg.pop("words", None)
            out.append(seg)
            continue

        labels = [_speaker_at(w["start"], w["end"], turns)
                  if w.get("start") is not None and w.get("end") is not None
                  else None for w in words]
        # smooth single-word flips:  A B A  ->  A A A
        for i in range(1, len(labels) - 1):
            if labels[i] != labels[i - 1] and labels[i - 1] == labels[i + 1]:
                labels[i] = labels[i - 1]

        run_start = 0
        for i in range(1, len(words) + 1):
            if i == len(words) or labels[i] != labels[run_start]:
                run = words[run_start:i]
                out.append({
                    "start": run[0]["start"] if run[0]["start"] is not None else seg["start"],
                    "end": run[-1]["end"] if run[-1]["end"] is not None else seg["end"],
                    "text": " ".join(w["word"] for w in run).strip(),
                    "speaker": labels[run_start] or _speaker_at(seg["start"], seg["end"], turns),
                })
                run_start = i
    return out


# ---- assembly --------------------------------------------------------------

def format_markdown(segments: list[dict], names: dict[str, str] | None = None) -> str:
    names = names or {}
    blocks: list[str] = []
    cur: object = object()
    buf: list[str] = []
    start = 0.0

    def flush() -> None:
        if buf:
            who = names.get(cur, cur if isinstance(cur, str) else "Unbekannt")
            blocks.append(f"**{who}** · {_hhmm(start)}\n\n{' '.join(buf).strip()}\n")

    for seg in segments:
        spk = seg.get("speaker") or "Unbekannt"
        if spk != cur:
            flush()
            cur, buf, start = spk, [], seg.get("start", 0.0)
        buf.append(seg.get("text", "").strip())
    flush()
    return "\n".join(blocks)


def _pick_model(cfg: dict) -> str:
    """The configured summary model, or the best available fallback if it's gone
    (models get removed from the shared Studio)."""
    s = cfg["summary"]
    want = s["ollama_model"]
    try:
        raw = urllib.request.urlopen(s["ollama_url"].rstrip("/") + "/api/tags", timeout=10).read()
        have = {m["name"] for m in json.loads(raw).get("models", [])}
    except Exception:  # noqa: BLE001
        return want
    if want in have:
        return want
    for cand in s.get("fallback_models", []) + sorted(have):
        if cand in have:
            print(f"[summary] '{want}' fehlt, nutze '{cand}'", flush=True)
            return cand
    return want


def summarize(transcript_md: str, cfg: dict) -> str:
    s = cfg["summary"]
    payload = {
        "model": _pick_model(cfg),
        "messages": [{"role": "user", "content": s["prompt"] + "\n\n---\n\n" + transcript_md}],
        "stream": False,
        "keep_alive": s.get("keep_alive", "30m"),
        "options": {"temperature": s.get("temperature", 0.0),
                    "num_ctx": s.get("num_ctx", 32768)},
    }
    req = urllib.request.Request(
        s["ollama_url"].rstrip("/") + "/api/chat",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as r:
        return json.loads(r.read())["message"]["content"].strip()


def transcribe_and_diarize(audio: Path, workdir: Path, cfg: dict, *,
                           names: dict[str, str] | None = None,
                           secondary_audio: Path | None = None) -> dict:
    """Phase 1 — audio → diarised transcript (no summary)."""
    workdir.mkdir(parents=True, exist_ok=True)
    wav = prepare_wav(audio, workdir / "prepared.wav", secondary_audio)

    segments, language = transcribe_segments(wav, cfg)
    turns, embeddings = diarize(wav, cfg)
    segments = assign_speakers(segments, turns)

    return {
        "transcript_md": format_markdown(segments, names),
        "speakers": sorted({s["speaker"] for s in segments if s.get("speaker")}),
        "language": language,
        "segments": segments,
        "embeddings": embeddings,
    }


def process(audio: Path, workdir: Path, cfg: dict, *,
            names: dict[str, str] | None = None, do_summary: bool = True,
            secondary_audio: Path | None = None) -> dict:
    """Full run (used by the CLI). The server runs the two phases separately."""
    r = transcribe_and_diarize(audio, workdir, cfg, names=names, secondary_audio=secondary_audio)
    r["summary_md"] = summarize(r["transcript_md"], cfg) if do_summary else None
    return r
