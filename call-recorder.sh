#!/bin/bash
# Запись звонков на Mac: оба голоса в один файл.
# CallTap пишет собеседника через Core Audio Process Tap (весь звук приложений Mac) и ваш голос с микрофона —
# AirPods, если они подключены, иначе микрофон по умолчанию. Маршрут звонка не меняется.
#   call-recorder on      — начать запись
#   call-recorder off     — остановить и сохранить
#   call-recorder status  — идёт ли запись
# Записи: ~/Movies/Записи звонков/«Звонок ….m4a» — оба голоса, выровненные по громкости;
#         в подпапке «Дорожки» — «Звонок ….mka» с собеседником и вами на отдельных дорожках (без выравнивания).
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
DIR="$HOME/.call-recorder"
APP="$DIR/CallTap.app"
BIN="$APP/Contents/MacOS/CallTap"
LOG="$DIR/logs/calltap.log"
CUR="$DIR/current"   # здесь лежит WAV, пока идёт запись
REC_DIR="$HOME/Movies/Записи звонков"

recording() { pgrep -f "$BIN record" >/dev/null; }

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
    # Через 3 с CallTap пишет первые уровни; полная тишина микрофона значит, что нет доступа к нему.
    for _ in $(seq 1 20); do grep -q "уровень" "$LOG" && break; sleep 0.25; done
    echo "✅ Идёт запись: $name"
    if grep "уровень" "$LOG" | head -1 | grep -q "микрофон   -inf"; then
        echo "⚠️  Микрофон пишет тишину. Если macOS спросила про доступ CallTap к микрофону — нажмите «Разрешить»,"
        echo "   затем остановите и снова начните запись."
        exit 3
    fi
}

stop() {
    if recording; then
        pkill -TERM -f "$BIN record"
        for _ in $(seq 1 40); do recording || break; sleep 0.25; done
    fi
    local found=0 w base gf gm
    mkdir -p "$REC_DIR/Дорожки"
    for w in "$CUR"/*.wav; do
        [ -f "$w" ] || continue
        found=1
        base=$(basename "$w" .wav)
        # Выравниваем голоса: каждую сторону приводим к одной громкости речи, потом смешиваем.
        gf=$(gain_for "$(loudness "$w" 0)"); gm=$(gain_for "$(loudness "$w" 1)")
        if ffmpeg -v error -y -i "$w" -filter_complex \
                "[0:a]pan=mono|c0=c0,volume=${gf}dB[far];[0:a]pan=mono|c0=c1,volume=${gm}dB[me];[far][me]amix=inputs=2:normalize=0,alimiter=limit=0.97:level=false" \
                -c:a aac -b:a 128k "$REC_DIR/$base.m4a" &&
           ffmpeg -v error -y -i "$w" -filter_complex "[0:a]pan=mono|c0=c0[far];[0:a]pan=mono|c0=c1[me]" \
                -map "[far]" -map "[me]" -c:a aac -b:a 96k \
                -metadata:s:a:0 title="Собеседник" -metadata:s:a:1 title="Я (микрофон)" "$REC_DIR/Дорожки/$base.mka"; then
            rm -f "$w"
            local secs; secs=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$REC_DIR/$base.m4a" | cut -d. -f1)
            echo "✅ Запись сохранена ($((secs / 60)) мин $((secs % 60)) с):"
            echo "   $REC_DIR/$base.m4a"
        else
            echo "❌ Не удалось преобразовать запись, исходный файл оставлен: $w"; exit 1
        fi
    done
    [ $found = 1 ] || echo "Запись не шла"
}

status() {
    if recording; then echo "Идёт запись — $(tail -1 "$LOG")"; else echo "Запись не идёт"; fi
}

case "${1:-}" in
    on|start) start ;;
    off|stop) stop ;;
    status) status ;;
    *) echo "использование: call-recorder on | off | status"; exit 2 ;;
esac
