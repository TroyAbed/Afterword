#!/usr/bin/env bash
# Transcribe a LOCAL audio file on the Mac Studio, get the results back here.
#
#   ./remote.sh ~/Movies/meeting.m4a
#   ./remote.sh --no-summary voice-memo.m4a
#
# One-time: passwordless SSH so it doesn't ask 3x per run —
#   ssh-keygen -t ed25519          # if you have no key yet
#   ssh-copy-id "$SCRIBE_HOST"     # default host below
#
# Override the host:  SCRIBE_HOST=maurusronner@maxpi ./remote.sh file.m4a
set -euo pipefail

HOST="${SCRIBE_HOST:-maurusronner@Mac-Studio-von-Maurus.local}"
# paths are relative to the SSH login dir ($HOME) — scp over SFTP does not
# expand ~ or $HOME on the remote side.
APP='whisper-service/app'
VENV='whisper-service/.venv/bin/activate'

opts=""; audio=""
for a in "$@"; do
  case "$a" in
    --no-summary) opts="$opts --no-summary" ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *)  audio="$a" ;;
  esac
done
[ -n "$audio" ] && [ -f "$audio" ] || { echo "usage: $0 [--no-summary] <audiofile>" >&2; exit 1; }

fname="$(basename "$audio")"
base="${fname%.*}"
outdir="$(dirname "$audio")"
run="run_$(date +%s)_$$"

echo "→ hochladen  ($fname)"
ssh "$HOST" "mkdir -p $APP/tmp/$run"
scp -q "$audio" "$HOST:$APP/tmp/$run/"

echo "→ transkribieren auf dem Studio …"
ssh "$HOST" "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH && source $VENV && cd $APP && python scribe.py 'tmp/$run/$fname' --outdir 'tmp/$run'$opts"

echo "→ Ergebnisse holen"
scp -q "$HOST:$APP/tmp/$run/$base.transcript.md" "$outdir/$base.transcript.md"
scp -q "$HOST:$APP/tmp/$run/$base.summary.md"    "$outdir/$base.summary.md" 2>/dev/null || true

ssh "$HOST" "rm -rf $APP/tmp/$run"

echo
echo "✓ $outdir/$base.transcript.md"
[ -f "$outdir/$base.summary.md" ] && echo "✓ $outdir/$base.summary.md"
