"""Voice library — match diarised speakers against saved voices.

Stored on the Studio at ~/whisper-service/voices/voices.json:
  { "Noa": {"vectors": [[...192 floats...], ...], "updated": "..."}, ... }
"""
from __future__ import annotations

import json
import math
from datetime import datetime, timezone
from pathlib import Path

DIR = Path.home() / "whisper-service" / "voices"
LIB = DIR / "voices.json"
MAX_SAMPLES = 12


def _load() -> dict:
    if LIB.exists():
        try:
            return json.loads(LIB.read_text())
        except Exception:  # noqa: BLE001
            pass
    return {}


def _save(d: dict) -> None:
    DIR.mkdir(parents=True, exist_ok=True)
    LIB.write_text(json.dumps(d, indent=2))


def names() -> list[dict]:
    return [{"name": n, "samples": len(v.get("vectors", []))}
            for n, v in sorted(_load().items())]


def add_sample(name: str, vector: list[float]) -> None:
    d = _load()
    entry = d.setdefault(name, {"vectors": []})
    entry["vectors"] = (entry.get("vectors", []) + [vector])[-MAX_SAMPLES:]
    entry["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    _save(d)


def remove(name: str) -> None:
    d = _load()
    d.pop(name, None)
    _save(d)


def pop_last(name: str) -> None:
    """Drop the most recent sample of a voice (undo a mis-label). Removes the
    voice entirely if that was its last sample."""
    d = _load()
    entry = d.get(name)
    if not entry:
        return
    entry["vectors"] = entry.get("vectors", [])[:-1]
    if entry["vectors"]:
        d[name] = entry
    else:
        d.pop(name, None)
    _save(d)


def _cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def match(embeddings: dict[str, list[float]], threshold: float) -> dict[str, str]:
    """label -> best-matching saved voice name (only if above `threshold`)."""
    lib = _load()
    out: dict[str, str] = {}
    for label, vec in embeddings.items():
        best_name, best_score = None, threshold
        for name, entry in lib.items():
            score = max((_cosine(vec, s) for s in entry.get("vectors", [])), default=0.0)
            if score > best_score:
                best_score, best_name = score, name
        if best_name:
            out[label] = best_name
    return out
