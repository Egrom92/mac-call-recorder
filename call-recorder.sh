#!/bin/bash
# Запись звонков на Mac: оба голоса в один файл.
# CallTap пишет собеседника через Core Audio Process Tap (весь звук приложений Mac) и ваш голос с микрофона —
# AirPods, если они подключены, иначе микрофон по умолчанию. Маршрут звонка не меняется.
#   call-recorder on      — начать запись
#   call-recorder off     — остановить и сохранить
#   call-recorder status  — идёт ли запись
# Записи: ~/Movies/Записи звонков/«Звонок <дата время>»/ — папка на каждый звонок с тремя файлами:
#         «… — оба голоса.m4a», «… — я.m4a», «… — собеседник.m4a» (громкость выровнена).
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
DIR="$HOME/.call-recorder"
APP="$DIR/CallTap.app"
BIN="$APP/Contents/MacOS/CallTap"
LOG="$DIR/logs/calltap.log"
CUR="$DIR/current"   # здесь лежит WAV, пока идёт запись
REC_DIR="$HOME/Movies/Записи звонков"

recording() { pgrep -f "$BIN record" >/dev/null; }
# Микрофон молчит: CallTap пишет уровни через 3 с и дальше раз в 10 с; первые секунды AirPods ещё
# переключаются в режим гарнитуры, поэтому смотрим только на последнюю строку после первой.
mic_silent() { [ "$(grep -c "уровень" "$LOG" 2>/dev/null)" -ge 2 ] && grep "уровень" "$LOG" | tail -1 | grep -q "микрофон   -inf"; }

# Громкость речи на канале WAV (0 — собеседник, 1 — микрофон), LUFS по EBU R128.
loudness() { ffmpeg -nostats -i "$1" -af "pan=mono|c0=c$2,ebur128" -f null - 2>&1 | awk '/^ +I:/ {v=$2} END {print v}'; }
# Усиление до −20 LUFS, но не больше +15 дБ (иначе вытянет шум) и не меньше −10 дБ.
gain_for() { awk -v l="$1" 'BEGIN { if (l == "" || l == "nan" || l + 0 < -69) { print 0; exit }
    g = -20 - l; if (g > 15) g = 15; if (g < -10) g = -10; printf "%.1f", g }'; }

start() {
    if recording; then echo "Запись уже идёт"; return 0; fi
    [ -x "$BIN" ] || { echo "❌ CallTap не установлен — запустите install.sh"; exit 1; }
    mkdir -p "$CUR" "$REC_DIR" "$DIR/logs"
    : > "$LOG"
    local name; name="Звонок $(date '+%Y-%m-%d %H-%M-%S')"
    open -n -g "$APP" --stdout "$LOG" --stderr "$LOG" --args record "$CUR/$name.wav"
    for _ in $(seq 1 20); do grep -qE "запись идёт|❌" "$LOG" && break; sleep 0.25; done
    if ! recording || ! grep -q "запись идёт" "$LOG"; then echo "❌ Запись не началась:"; cat "$LOG"; exit 1; fi
    echo "✅ Идёт запись: $name"
}

stop() {
    if recording; then
        pkill -TERM -f "$BIN record"
        for _ in $(seq 1 40); do recording || break; sleep 0.25; done
    fi
    local found=0 w base out gf gm
    for w in "$CUR"/*.wav; do
        [ -f "$w" ] || continue
        found=1
        base=$(basename "$w" .wav)
        out="$REC_DIR/$base"
        mkdir -p "$out"
        # Каждую сторону приводим к одной громкости речи; из неё делаем отдельный файл и общий микс.
        gf=$(gain_for "$(loudness "$w" 0)"); gm=$(gain_for "$(loudness "$w" 1)")
        if ffmpeg -v error -y -i "$w" -filter_complex \
                "[0:a]pan=mono|c0=c0,volume=${gf}dB,asplit[f1][f2];[0:a]pan=mono|c0=c1,volume=${gm}dB,asplit[m1][m2];[f1][m1]amix=inputs=2:normalize=0,alimiter=limit=0.97:level=false[mix];[f2]alimiter=limit=0.97:level=false[far];[m2]alimiter=limit=0.97:level=false[me]" \
                -map "[mix]" -c:a aac -b:a 128k -metadata title="$base — оба голоса" "$out/$base — оба голоса.m4a" \
                -map "[me]" -c:a aac -b:a 96k -metadata title="$base — я" "$out/$base — я.m4a" \
                -map "[far]" -c:a aac -b:a 96k -metadata title="$base — собеседник" "$out/$base — собеседник.m4a"; then
            rm -f "$w"
            local secs; secs=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$out/$base — оба голоса.m4a" | cut -d. -f1)
            echo "✅ Запись сохранена ($((secs / 60)) мин $((secs % 60)) с) в папку:"
            echo "   $out"
            echo "   «оба голоса», «я» и «собеседник» — отдельными файлами"
        else
            echo "❌ Не удалось преобразовать запись, исходный файл оставлен: $w"; exit 1
        fi
    done
    [ $found = 1 ] || echo "Запись не шла"
}

status() {
    if recording; then
        echo "Идёт запись — $(grep "уровень" "$LOG" | tail -1)"
        if mic_silent; then echo "⚠️  Микрофон молчит: разрешите CallTap доступ к микрофону (Системные настройки → Конфиденциальность и безопасность → Микрофон)"; fi
    else
        echo "Запись не идёт"
    fi
}

case "${1:-}" in
    on|start) start ;;
    off|stop) stop ;;
    status) status ;;
    *) echo "использование: call-recorder on | off | status"; exit 2 ;;
esac
