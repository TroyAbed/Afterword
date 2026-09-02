#!/usr/bin/env python3
"""Submit a local audio file to the Afterword HTTP service, wait, save results.

Runs on your Mac (Pro / Air). Replaces the SSH-based remote.sh once the service
is up.

    python client.py ~/Movies/meeting.m4a
    python client.py --kind meeting --title "Standup" call.m4a
    SCRIBE_URL=http://mac-studio-von-maurus.local:8756 SCRIBE_TOKEN=xxx python client.py f.m4a
"""
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import sys
import time
import urllib.request
from pathlib import Path

BASE = os.environ.get("SCRIBE_URL", "http://mac-studio-von-maurus.local:8756").rstrip("/")
TOKEN = os.environ.get("SCRIBE_TOKEN", "")


def _req(path: str, data: bytes | None = None,
         headers: dict | None = None, method: str | None = None) -> dict:
    h = {"Authorization": f"Bearer {TOKEN}"} if TOKEN else {}
    h.update(headers or {})
    req = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())


def _multipart(fields: dict[str, str], name: str, filepath: Path) -> tuple[bytes, str]:
    boundary = "----scribe" + os.urandom(8).hex()
    parts = []
    for k, v in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    ctype = mimetypes.guess_type(filepath.name)[0] or "application/octet-stream"
    parts.append(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; "
        f"filename=\"{filepath.name}\"\r\nContent-Type: {ctype}\r\n\r\n".encode())
    parts.append(filepath.read_bytes())
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("audio", type=Path)
    ap.add_argument("--kind", default="voicenote", choices=["meeting", "voicenote"])
    ap.add_argument("--title", default="")
    ap.add_argument("--language", default="")
    args = ap.parse_args()
    if not args.audio.exists():
        sys.exit(f"no such file: {args.audio}")

    body, ctype = _multipart(
        {"kind": args.kind, "title": args.title, "language": args.language},
        "audio", args.audio)
    job = _req("/jobs", data=body, headers={"Content-Type": ctype}, method="POST")
    jid = job["id"]
    print(f"job {jid}  ({args.kind})")

    while True:
        j = _req(f"/jobs/{jid}")
        if j["status"] == "done":
            break
        if j["status"] == "error":
            print("ERROR:", j.get("error"))
            print(j.get("traceback", ""))
            sys.exit(1)
        print(f"  {j['status']} …")
        time.sleep(4)

    out = args.audio.parent
    (out / f"{args.audio.stem}.transcript.md").write_text(j["transcript_md"] or "")
    print("✓", out / f"{args.audio.stem}.transcript.md")
    if j.get("summary_md"):
        (out / f"{args.audio.stem}.summary.md").write_text(j["summary_md"])
        print("✓", out / f"{args.audio.stem}.summary.md")
    print("  Sprecher:", ", ".join(j.get("speakers_detected", [])) or "–")


if __name__ == "__main__":
    main()
