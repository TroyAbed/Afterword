#!/usr/bin/env bash
# Push code + LaunchAgent to the Mac Studio and restart the service.
# Run from your Mac Pro in ~/Afterword. Asks for the Studio password.
# Does NOT touch token.txt / data/ on the Studio.
set -euo pipefail

HOST="${SCRIBE_HOST:-maurusronner@mac-studio-von-maurus.local}"

ssh "$HOST" "mkdir -p whisper-service/app Library/LaunchAgents"
scp pipeline.py voices.py scribe.py server.py watch.py client.py config.toml \
    "$HOST:whisper-service/app/"
scp com.afterword.server.plist "$HOST:Library/LaunchAgents/"

ssh "$HOST" 'set -e
  U="gui/$(id -u)"
  # kill the pre-rename agent if it is still around (fought over port 8756)
  launchctl bootout "$U/com.meetingscribe.server" 2>/dev/null || true
  rm -f ~/Library/LaunchAgents/com.meetingscribe.server.plist
  launchctl bootout "$U/com.afterword.server" 2>/dev/null || true
  pkill -f "uvicorn server:app" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "$U" ~/Library/LaunchAgents/com.afterword.server.plist 2>/dev/null \
    || launchctl load ~/Library/LaunchAgents/com.afterword.server.plist
  sleep 3
  curl -s localhost:8756/health && echo || echo "!! service not responding — check ~/whisper-service/server.log"'

echo "✓ deployed + service restarted on $HOST"
