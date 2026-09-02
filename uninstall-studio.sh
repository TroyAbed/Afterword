#!/usr/bin/env bash
# Restlos alles entfernen, was dieses Projekt auf dem Mac Studio installiert hat.
#
#   Vom Mac Pro:
#     scp ~/Afterword/uninstall-studio.sh maurusronner@mac-studio-von-maurus.local:~/
#   Auf dem Studio:
#     bash ~/uninstall-studio.sh
#
# Fasst NICHT an: Ollama, dessen LaunchAgent (ollama.network.plist), oder sonst
# etwas ausserhalb dieses Projekts.
set -u
echo "── Afterword / whisper-service deinstallieren ──"
echo

# 1) LaunchAgent stoppen + löschen
PLIST=~/Library/LaunchAgents/com.afterword.server.plist
if [ -f "$PLIST" ]; then
    launchctl bootout "gui/$(id -u)/com.afterword.server" 2>/dev/null \
        || launchctl unload "$PLIST" 2>/dev/null
    rm -f "$PLIST"
    echo "✓ LaunchAgent entfernt"
else
    echo "· LaunchAgent nicht vorhanden"
fi

# 2) laufende Server-Prozesse killen
pkill -f "uvicorn server:app" 2>/dev/null && echo "✓ laufenden Server gestoppt" || true

# 3) das Projektverzeichnis (venv, Code, Modelle, Job-Daten, alles)
if [ -d ~/whisper-service ]; then
    SZ=$(du -sh ~/whisper-service 2>/dev/null | cut -f1)
    rm -rf ~/whisper-service
    echo "✓ ~/whisper-service gelöscht ($SZ)"
else
    echo "· ~/whisper-service nicht vorhanden"
fi

# 4) verstreute Caches ausserhalb des Projekts (falls vor dem HF_HOME-Umzug angelegt)
for d in ~/.cache/huggingface ~/.cache/torch ~/.cache/matplotlib ~/.cache/mlx ~/.huggingface; do
    [ -e "$d" ] && { rm -rf "$d"; echo "✓ $d gelöscht"; }
done

# 5) HuggingFace-Token aus dem Schlüsselbund (der Web-Token sollte eh widerrufen sein)
printf 'protocol=https\nhost=huggingface.co\n\n' | git credential-osxkeychain erase 2>/dev/null \
    && echo "✓ HF-Token aus dem Schlüsselbund entfernt" || true

# 6) Test-Reste in /tmp
rm -rf /tmp/testpipe.log /tmp/t2.log /tmp/t3.log /tmp/mlxdl.log /tmp/pw /tmp/p.wav 2>/dev/null
echo "✓ /tmp aufgeräumt"

# 7) Homebrew-Pakete — nur entfernen, wenn nichts anderes sie braucht
BREW=/opt/homebrew/bin/brew
echo
echo "── Homebrew ──"
for f in ffmpeg python@3.12; do
    if ! $BREW list --versions "$f" >/dev/null 2>&1; then
        echo "· $f nicht via brew installiert"
        continue
    fi
    USES=$($BREW uses --installed --recursive "$f" 2>/dev/null)
    if [ -n "$USES" ]; then
        echo "⚠ $f wird noch gebraucht von: $(echo "$USES" | tr '\n' ' ')— NICHT entfernt"
    else
        $BREW uninstall "$f" 2>/dev/null && echo "✓ $f entfernt" || echo "⚠ $f konnte nicht entfernt werden"
    fi
done
echo
echo "Optional, prüft verwaiste brew-Abhängigkeiten (nur Anzeige, entfernt nichts):"
echo "    brew autoremove -n"

echo
echo "── fertig ──"
echo "Entfernt: LaunchAgent, ~/whisper-service (venv inkl. mlx-whisper/whisperx/"
echo "pyannote/fastapi/…, alle Modelle, alle Aufnahmen + Transkripte), Caches,"
echo "Schlüsselbund-Token, ggf. ffmpeg + python@3.12."
echo "Unangetastet: Ollama und alles andere auf dem Rechner."
