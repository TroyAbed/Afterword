#!/usr/bin/env python3
"""CLI wrapper over pipeline.py.

    python scribe.py meeting.m4a
    python scribe.py meeting.m4a --outdir output --speakers speakers.json --no-summary
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import pipeline

CFG = pipeline.load_config()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("audio", type=Path)
    ap.add_argument("--outdir", type=Path)
    ap.add_argument("--speakers", type=Path,
                    help='JSON map, e.g. {"SPEAKER_00": "Thomas"}')
    ap.add_argument("--no-summary", action="store_true")
    args = ap.parse_args()

    if not args.audio.exists():
        sys.exit(f"no such file: {args.audio}")
    outdir = args.outdir or args.audio.parent
    outdir.mkdir(parents=True, exist_ok=True)
    names = {}
    if args.speakers and args.speakers.exists():
        names = json.loads(args.speakers.read_text())

    print(f"[1/3] whisperx  ({args.audio.name})")
    res = pipeline.process(args.audio, outdir, CFG, names=names,
                           do_summary=not args.no_summary)
    print(f"      Sprecher: {', '.join(res['speakers'])}  ·  Sprache: {res['language']}")

    print("[2/3] Transkript")
    tpath = outdir / f"{args.audio.stem}.transcript.md"
    tpath.write_text(f"# {args.audio.stem}\n\n{res['transcript_md']}")
    print(f"      -> {tpath}")

    if res["summary_md"]:
        print(f"[3/3] Zusammenfassung  ({CFG['summary']['ollama_model']})")
        spath = outdir / f"{args.audio.stem}.summary.md"
        spath.write_text(f"# Protokoll — {args.audio.stem}\n\n{res['summary_md']}\n")
        print(f"      -> {spath}")


if __name__ == "__main__":
    main()
