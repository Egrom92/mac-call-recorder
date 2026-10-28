#!/bin/bash
# Запись звонков на Mac: оба голоса в один файл.
# CallTap пишет собеседника через Core Audio Process Tap (весь звук приложений Mac) и ваш голос с микрофона —
# AirPods, если они подключены, иначе микрофон по умолчанию. Маршрут звонка не меняется.
#   call-recorder on ["Имя клиента"]  — начать запись (имя попадёт в название папки)
#   call-recorder off                 — остановить и сохранить (и отправить на сервер, если он настроен)
#   call-recorder status              — идёт ли запись, эфир, сервер
#   call-recorder split on|off        — сохранять ли голоса отдельными файлами (по умолчанию да)
#   call-recorder live on|off         — «Прямой эфир»: звук потоком на сервер во время записи (по умолчанию нет)
#   call-recorder server <адрес>      — адрес сервера, например https://crm.example.com
#   call-recorder token               — ввести ключ сервера (INBOX_TOKEN); хранится в ~/.call-recorder/inbox-token
#   call-recorder upload              — повторить отправку записей, которые не ушли на сервер
# Записи: ~/Movies/Записи звонков/«ГГГГ-ММ-ДД_ЧЧ-ММ_Имя клиента»/ — папка на каждый звонок с тремя файлами:
#         «… — оба голоса.m4a», «… — я.m4a», «… — собеседник.m4a» (громкость выровнена).
#         С split off — один файл «ГГГГ-ММ-ДД_ЧЧ-ММ_Имя клиента.m4a» с обоими голосами.
# Сервер (если задан адрес и ключ): после записи файлы уходят в его inbox как me.m4a / them.m4a / mix.m4a с пометкой
# готовности; с «Прямым эфиром» звук во время записи идёт кусками на /api/live/chunk (программа LiveStream).
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"   # имена клиентов кириллицей: обрезка и замены по символам, а не байтам
DIR="${CALL_RECORDER_DIR:-$HOME/.call-recorder}"   # CALL_RECORDER_DIR — только для тестов
APP="$DIR/CallTap.app"
BIN="$APP/Contents/MacOS/CallTap"
LIVE_BIN="$DIR/LiveStream"
LOG="$DIR/logs/calltap.log"
CUR="$DIR/current"           # здесь лежит WAV, пока идёт запись
SETTINGS="$DIR/settings"     # строки вида split=no, live=yes, server=https://…; их же меняет кнопка в строке меню
TOKEN_FILE="$DIR/inbox-token"
UPLOADS="$DIR/uploads"       # состояние отправки каждой записи: uploading / ok / failed и путь к ней
REC_DIR="${CALL_RECORDER_REC_DIR:-$HOME/Movies/Записи звонков}"   # CALL_RECORDER_REC_DIR — только для тестов

setting() { sed -n "s/^$1=//p" "$SETTINGS" 2>/dev/null | tail -1; }
set_setting() {
    mkdir -p "$DIR"
    { grep -v "^$1=" "$SETTINGS" 2>/dev/null; echo "$1=$2"; } > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
}
split_enabled() { [ "$(setting split)" != "no" ]; }
live_enabled() { [ "$(setting live)" = "yes" ]; }
server_url() { setting server | sed 's#/*$##'; }
server_ready() { [ -n "$(server_url)" ] && [ -s "$TOKEN_FILE" ]; }

recording() { pgrep -f "$BIN record" >/dev/null; }
live_running() { pgrep -f "$LIVE_BIN " >/dev/null; }
# Микрофон молчит: CallTap пишет уровни через 3 с и дальше раз в 10 с; первые секунды AirPods ещё
# переключаются в режим гарнитуры, поэтому смотрим только на последнюю строку после первой.
mic_silent() { [ "$(grep -c "уровень" "$LOG" 2>/dev/null)" -ge 2 ] && grep "уровень" "$LOG" | tail -1 | grep -q "микрофон   -inf"; }

# Громкость речи на канале WAV (0 — собеседник, 1 — микрофон), LUFS по EBU R128.
loudness() { ffmpeg -nostats -i "$1" -af "pan=mono|c0=c$2,ebur128" -f null - 2>&1 | awk '/^ +I:/ {v=$2} END {print v}'; }
# Усиление до −20 LUFS, но не больше +15 дБ (иначе вытянет шум) и не меньше −10 дБ.
gain_for() { awk -v l="$1" 'BEGIN { if (l == "" || l == "nan" || l + 0 < -69) { print 0; exit }
    g = -20 - l; if (g > 15) g = 15; if (g < -10) g = -10; printf "%.1f", g }'; }

# Имя записи — оно же имя папки и сессии эфира на сервере: ГГГГ-ММ-ДД_ЧЧ-ММ_Имя клиента
# (без имени — только дата и время). Без «/» и «\», не начинается с точки, не длиннее 120 символов.
session_name() {
    local client="${1:-}"
    client="${client//\//-}"; client="${client//\\/-}"
    client=$(printf '%s' "$client" | sed -E 's/^[[:space:].]+//; s/[[:space:]]+$//')
    client="${client:0:100}"
    local stamp; stamp=$(date '+%Y-%m-%d_%H-%M')
    if [ -n "$client" ]; then printf '%s_%s' "$stamp" "$client"; else printf '%s' "$stamp"; fi
}

# POST на сервер с ключом. Ключ идёт заголовком через отдельный поток: его не видно ни в списке процессов, ни в журналах.
api() {  # $1 — путь (/api/…), дальше — аргументы curl
    local path="$1"; shift
    curl -sS --fail-with-body --max-time "${API_TIMEOUT:-15}" -X POST \
        -H @<(printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$TOKEN_FILE")") "$@" "$(server_url)$path"
}

start() {
    if recording; then echo "Запись уже идёт"; return 0; fi
    [ -x "$BIN" ] || { echo "❌ CallTap не установлен — запустите install.sh"; exit 1; }
    mkdir -p "$CUR" "$REC_DIR" "$DIR/logs"
    : > "$LOG"
    local name; name=$(session_name "${1:-}")
    # Два звонка за одну минуту с тем же именем не должны затирать друг друга (и на сервере это разные разговоры).
    local first="$name" n=2
    while [ -e "$REC_DIR/$name" ] || [ -e "$REC_DIR/$name.m4a" ] || [ -e "$CUR/$name.wav" ]; do
        name="${first}_${n}"; n=$((n + 1))
    done
    open -n -g "$APP" --stdout "$LOG" --stderr "$LOG" --args record "$CUR/$name.wav"
    # CallTap может повторить запуск, если AirPods как раз переключаются в режим гарнитуры, — ждём до 10 с.
    for _ in $(seq 1 40); do grep -qE "запись идёт|❌" "$LOG" && break; sleep 0.25; done
    if ! recording || ! grep -q "запись идёт" "$LOG"; then echo "❌ Запись не началась:"; cat "$LOG"; exit 1; fi
    echo "✅ Идёт запись: $name"
    if live_enabled; then start_live "$name"; fi
}

# Прямой эфир — отдельный процесс LiveStream: читает тот же WAV и шлёт куски на сервер. Если он упадёт
# или сети нет, запись идёт как обычно.
start_live() {
    local name="$1"
    if ! server_ready; then echo "⚠️  Прямой эфир не включён: не заданы адрес сервера или ключ"; return 0; fi
    [ -x "$LIVE_BIN" ] || { echo "⚠️  Прямой эфир не включён: LiveStream не установлен — запустите install.sh"; return 0; }
    printf 'wait\n' > "$DIR/logs/live-status"
    printf '%s\n' "$name" > "$CUR/.live-session"
    nohup "$LIVE_BIN" "$CUR/$name.wav" "$name" "$(server_url)" >> "$DIR/logs/live.log" 2>&1 &
    echo "📡 Прямой эфир включён"
}

# Остановить LiveStream (он дочитает хвост и отправит последний кусок) и сообщить серверу, что разговор окончен.
stop_live() {
    if live_running; then
        pkill -TERM -f "$LIVE_BIN "
        for _ in $(seq 1 80); do live_running || break; sleep 0.1; done
    fi
    local name; name=$(cat "$CUR/.live-session" 2>/dev/null) || return 0
    rm -f "$CUR/.live-session"
    [ -n "$name" ] && server_ready || return 0
    if API_TIMEOUT=10 api /api/live/end --url-query "session=$name" -o /dev/null 2>/dev/null; then echo "📡 Эфир завершён"
    else echo "⚠️  Сервер не подтвердил конец эфира (закроет его сам через 2 минуты)"; fi
}

stop() {
    if recording; then
        pkill -TERM -f "$BIN record"
        for _ in $(seq 1 40); do recording || break; sleep 0.25; done
    fi
    stop_live
    local found=0 empty=0 w base out gf gm dur
    for w in "$CUR"/*.wav; do
        [ -f "$w" ] || continue
        found=1
        base=$(basename "$w" .wav)
        dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$w" 2>/dev/null | cut -d. -f1)
        if ! [ "${dur:-0}" -ge 1 ] 2>/dev/null; then
            rm -f "$w"; empty=1
            echo "⚠️ Запись «${base}» пустая: звук не поступал. Начните запись ещё раз."
            continue
        fi
        # Каждую сторону приводим к одной громкости речи; из неё делаем отдельные файлы и общий микс.
        gf=$(gain_for "$(loudness "$w" 0)"); gm=$(gain_for "$(loudness "$w" 1)")
        local sides="[0:a]pan=mono|c0=c0,volume=${gf}dB,asplit[f1][f2];[0:a]pan=mono|c0=c1,volume=${gm}dB,asplit[m1][m2]"
        local mix="[f1][m1]amix=inputs=2:normalize=0,alimiter=limit=0.97:level=false[mix]"
        local ok=0 saved target
        if split_enabled; then
            out="$REC_DIR/$base"
            mkdir -p "$out"
            saved="$out/$base — оба голоса.m4a"
            target="$out"
            ffmpeg -v error -y -i "$w" -filter_complex \
                "$sides;$mix;[f2]alimiter=limit=0.97:level=false[far];[m2]alimiter=limit=0.97:level=false[me]" \
                -map "[mix]" -c:a aac -b:a 128k -metadata title="$base — оба голоса" "$saved" \
                -map "[me]" -c:a aac -b:a 96k -metadata title="$base — я" "$out/$base — я.m4a" \
                -map "[far]" -c:a aac -b:a 96k -metadata title="$base — собеседник" "$out/$base — собеседник.m4a" && ok=1
        else
            saved="$REC_DIR/$base.m4a"
            target="$saved"
            ffmpeg -v error -y -i "$w" -filter_complex "$sides;$mix;[f2]anullsink;[m2]anullsink" \
                -map "[mix]" -c:a aac -b:a 128k -metadata title="$base" "$saved" && ok=1
        fi
        if [ $ok = 1 ]; then
            rm -f "$w"
            local secs; secs=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$saved" | cut -d. -f1)
            echo "✅ Запись сохранена ($((secs / 60)) мин $((secs % 60)) с):"
            if split_enabled; then
                echo "   $out"
                echo "   «оба голоса», «я» и «собеседник» — отдельными файлами"
            else
                echo "   $saved"
            fi
            # Отправка на сервер идёт в фоне: «Завершить запись» не ждёт загрузку.
            if server_ready; then
                mkdir -p "$UPLOADS"
                printf 'uploading\n%s\n' "$target" > "$UPLOADS/$base"
                nohup bash "$DIR/call-recorder.sh" upload-one "$target" "$base" >> "$DIR/logs/upload.log" 2>&1 &
                echo "☁️  Отправка на сервер началась"
            fi
        else
            echo "❌ Не удалось преобразовать запись, исходный файл оставлен: $w"; exit 1
        fi
    done
    [ $found = 1 ] || echo "Запись не шла"
    [ $empty = 0 ] || exit 4
}

# Отправка одной записи в inbox сервера: me / them / mix, затем пометка готовности (протокол docs/INBOX.md в CRM).
upload_one() {  # $1 — папка записи или один .m4a (без разделения голосов), $2 — имя папки на сервере
    local src="$1" folder="$2" ok=1 f remote pair
    mkdir -p "$UPLOADS"
    printf 'uploading\n%s\n' "$src" > "$UPLOADS/$folder"
    echo "$(date '+%F %T') отправка «${folder}»"
    if [ -d "$src" ]; then
        for pair in "я:me" "собеседник:them" "оба голоса:mix"; do
            f="$src/$folder — ${pair%%:*}.m4a"; remote="${pair##*:}.m4a"
            [ -f "$f" ] || continue
            API_TIMEOUT=900 api /api/inbox --url-query "folder=$folder" --url-query "file=$remote" \
                -H 'Content-Type: application/octet-stream' -H 'Expect:' -T "$f" \
                --retry 3 --retry-delay 5 --retry-all-errors -o /dev/null || { ok=0; echo "   ❌ $remote не отправлен"; }
        done
    else
        API_TIMEOUT=900 api /api/inbox --url-query "folder=$folder" --url-query "file=mix.m4a" \
            -H 'Content-Type: application/octet-stream' -H 'Expect:' -T "$src" \
            --retry 3 --retry-delay 5 --retry-all-errors -o /dev/null || { ok=0; echo "   ❌ mix.m4a не отправлен"; }
    fi
    if [ $ok = 1 ] && API_TIMEOUT=30 api /api/inbox/done --url-query "folder=$folder" --retry 3 --retry-all-errors -o /dev/null; then
        printf 'ok\n%s\n' "$src" > "$UPLOADS/$folder"
        echo "   ✅ отправлено"
    else
        printf 'failed\n%s\n' "$src" > "$UPLOADS/$folder"
        echo "   ❌ не отправлено — повторить: call-recorder upload"
        return 1
    fi
}

# Повторить отправку всех записей, которые не ушли.
upload_failed() {
    server_ready || { echo "❌ Не заданы адрес сервера или ключ"; exit 1; }
    local s any=0
    for s in "$UPLOADS"/*; do
        [ -f "$s" ] && [ "$(head -1 "$s")" = "failed" ] || continue
        any=1
        upload_one "$(sed -n 2p "$s")" "$(basename "$s")"
    done
    [ $any = 1 ] || echo "Неотправленных записей нет"
}

status() {
    if recording; then
        echo "Идёт запись — $(grep "уровень" "$LOG" | tail -1)"
        if mic_silent; then echo "⚠️  Микрофон молчит: разрешите CallTap доступ к микрофону (Системные настройки → Конфиденциальность и безопасность → Микрофон)"; fi
        if live_running; then echo "📡 Прямой эфир: $(cat "$DIR/logs/live-status" 2>/dev/null)"; fi
    else
        echo "Запись не идёт"
    fi
    if split_enabled; then echo "Голоса сохраняются отдельно: оба / я / собеседник"; else echo "Сохраняется один файл с обоими голосами"; fi
    local srv; srv=$(server_url)
    echo "Сервер: ${srv:-не задан}, $( [ -s "$TOKEN_FILE" ] && echo "ключ задан" || echo "ключ не задан")"
    if live_enabled; then echo "Прямой эфир: включён"; else echo "Прямой эфир: выключен"; fi
}

set_onoff() {  # $1 — ключ настройки, $2 — on|off
    case "${2:-}" in
        on|yes) set_setting "$1" yes ;;
        off|no) set_setting "$1" no ;;
        *) echo "использование: call-recorder $1 on | off"; exit 2 ;;
    esac
}

set_token() {
    local t
    if [ -t 0 ]; then read -r -s -p "Вставьте ключ сервера (INBOX_TOKEN) и нажмите Enter: " t; echo; else IFS= read -r t || true; fi
    t=$(printf '%s' "$t" | tr -d '[:space:]')
    [ -n "$t" ] || { echo "Ключ пустой — ничего не изменено"; exit 1; }
    mkdir -p "$DIR"
    (umask 077; printf '%s\n' "$t" > "$TOKEN_FILE")
    chmod 600 "$TOKEN_FILE"
    echo "✅ Ключ сохранён (доступ к файлу только у вас)"
}

set_server() {
    case "${1:-}" in
        https://*|http://*) set_setting server "$(printf '%s' "$1" | sed 's#/*$##')"; echo "✅ Сервер: $(server_url)" ;;
        *) echo "использование: call-recorder server https://crm.example.com"; exit 2 ;;
    esac
}

case "${1:-}" in
    on|start) start "${2:-}" ;;
    off|stop) stop ;;
    status) status ;;
    split)
        set_onoff split "${2:-}"
        if split_enabled; then echo "✅ Голоса будут сохраняться отдельно: оба / я / собеседник"
        else echo "✅ Будет сохраняться один файл с обоими голосами"; fi ;;
    live)
        set_onoff live "${2:-}"
        if live_enabled; then echo "✅ Прямой эфир включён$(server_ready || echo " — задайте адрес сервера и ключ: call-recorder server …, call-recorder token")"
        else echo "✅ Прямой эфир выключен"; fi ;;
    server) set_server "${2:-}" ;;
    token) set_token ;;
    upload) upload_failed ;;
    upload-one) upload_one "${2:-}" "${3:-}" ;;
    *) echo "использование: call-recorder on [\"Имя клиента\"] | off | status | split on|off | live on|off | server <адрес> | token | upload"; exit 2 ;;
esac
