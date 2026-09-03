#!/usr/bin/env bash
# Dev run without installing — needs PySide6 (system package or a venv).
set -e
cd "$(dirname "$0")"
if ! python -c "import PySide6" 2>/dev/null; then
  [ -d .venv ] || python -m venv .venv
  .venv/bin/pip install -q -r requirements.txt
  exec .venv/bin/python -m afterword "$@"
fi
exec python -m afterword "$@"
