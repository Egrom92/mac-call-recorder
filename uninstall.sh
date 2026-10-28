#!/bin/bash
# Удаление «Запись звонков». Записи в ~/Movies/Записи звонков остаются на месте.
#   curl -fsSL https://raw.githubusercontent.com/Egrom92/mac-call-recorder/main/uninstall.sh | bash
set -u
DIR="$HOME/.call-recorder"

if [ -x "$DIR/call-recorder.sh" ] && pgrep -f "$DIR/CallTap.app/Contents/MacOS/CallTap record" >/dev/null; then
    echo "▶︎ Останавливаю и сохраняю текущую запись"
    "$DIR/call-recorder.sh" off
fi
pkill -f "Запись звонков.app/Contents/MacOS/CallRecorderMenu" 2>/dev/null
pkill -f "$DIR/CallTap.app/Contents/MacOS/CallTap" 2>/dev/null
pkill -f "$DIR/LiveStream " 2>/dev/null

for b in /opt/homebrew/bin /usr/local/bin; do
    [ -L "$b/call-recorder" ] && rm -f "$b/call-recorder"
done
rm -rf "$HOME/Applications/Запись звонков.app" "$DIR/CallTap.app" "$DIR/call-recorder.sh" "$DIR/logs" \
       "$DIR/settings" "$DIR/.calltap-source.sha256" "$DIR/LiveStream" "$DIR/inbox-token" "$DIR/uploads"
rmdir "$DIR/current" "$DIR" 2>/dev/null

echo "✅ «Запись звонков» удалена. Записи остались в ~/Movies/Записи звонков."
echo "   BlackHole и ffmpeg, если они больше не нужны: brew uninstall --cask blackhole-2ch; brew uninstall ffmpeg"
echo "   Разрешения CallTap можно убрать в Системных настройках → Конфиденциальность и безопасность."
