#!/bin/bash
# Запись звонков на Mac: оба голоса в один файл.
# CallTap пишет собеседника через Core Audio Process Tap (весь звук приложений Mac) и ваш голос с микрофона —
# AirPods, если они подключены, иначе микрофон по умолчанию. Маршрут звонка не меняется.
#   call-recorder on ["Имя клиента"]  — начать запись (имя попадёт в название папки)
#   call-recorder on --name-later     — начать запись сразу, имя клиента — потом командой name (так делает кнопка в меню)
#   call-recorder name ["Имя клиента"] — имя для идущей записи, начатой без него; включает «Прямой эфир»
#   call-recorder off                 — остановить и сохранить (и отправить на сервер, если он настроен)
#   call-recorder status              — идёт ли запись, эфир, сервер
#   call-recorder split on|off        — сохранять ли голоса отдельными файлами (по умолчанию да)
#   call-recorder live on|off         — «Прямой эфир»: звук потоком на сервер во время записи (по умолчанию нет)
#   call-recorder server <адрес>      — адрес сервера, например https://crm.example.com
#   call-recorder token               — ввести ключ сервера (INBOX_TOKEN); хранится в ~/.call-recorder/inbox-token
#   call-recorder upload              — повторить отправку записей, которые не ушли на сервер
#   call-recorder errors [N]          — последние N событий журнала ошибок (по умолчанию 30)
#   call-recorder send-logs           — отправить журнал ошибок на сервер сейчас (сам уходит после записи и раз в 30 с из меню)
# Записи: ~/Movies/Записи звонков/«ГГГГ-ММ-ДД_ЧЧ-ММ_Имя клиента»/ — папка на каждый звонок с тремя файлами:
#         «… — оба голоса.m4a», «… — я.m4a», «… — собеседник.m4a» (громкость выровнена).
#         С split off — один файл «ГГГГ-ММ-ДД_ЧЧ-ММ_Имя клиента.m4a» с обоими голосами.
# Сервер (если задан адрес и ключ): после записи файлы уходят в его inbox как me.m4a / them.m4a / mix.m4a с пометкой
# готовности; с «Прямым эфиром» звук во время записи идёт кусками на /api/live/chunk (программа LiveStream).
# Журнал ошибок уходит туда же на /api/logs.
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
ERRLOG="$DIR/logs/errors.jsonl"   # журнал ошибок всех частей программы: строка JSON на событие (README, «Журнал ошибок»)
SENT_POS="$DIR/logs/send-logs.pos"         # докуда журнал отправлен на сервер: «номер файла (inode) позиция в байтах»
SEND_STATUS="$DIR/logs/send-logs.status"   # итог последней отправки журнала: ok | retry | forbidden, с какого времени, причина
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

# --- Журнал ошибок ---------------------------------------------------------------
# Строка → JSON-строка в кавычках: кириллица как есть, перевод строки → \n, прочие управляющие символы убираются.
json_str() {
    printf '"%s"' "$(printf '%s' "$1" | tr '\t\r' '  ' | tr -d '\000-\010\013\014\016-\037' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
}

# Событие в журнал: log_event <источник> <error|warning|info> <код события> <сообщение> [ключ=значение …].
# Ключ session становится полем session, остальные — полями details. Ключ сервера сюда не передаётся никогда.
log_event() {
    local source="$1" level="$2" event="$3" message="$4" kv session="" details="" extra=""; shift 4
    for kv in "$@"; do
        if [ "${kv%%=*}" = session ]; then session="${kv#*=}"; continue; fi
        details+="${details:+,}$(json_str "${kv%%=*}"):$(json_str "${kv#*=}")"
    done
    [ -n "$session" ] && extra+=",\"session\":$(json_str "$session")"
    extra+=",\"host\":$(json_str "$(scutil --get ComputerName 2>/dev/null || hostname -s)")"
    extra+=",\"version\":$(json_str "$(cat "$DIR/version" 2>/dev/null || echo dev)")"
    [ -n "$details" ] && extra+=",\"details\":{$details}"
    mkdir -p "$DIR/logs"
    # Больше 2 МБ — старый журнал уходит в errors.jsonl.1 (одна предыдущая копия).
    [ "$(stat -f%z "$ERRLOG" 2>/dev/null || echo 0)" -lt 2000000 ] || mv -f "$ERRLOG" "$ERRLOG.1"
    printf '{"id":"%s","time":"%s","level":"%s","source":"%s","event":"%s","message":%s%s}\n' \
        "$(uuidgen | tr 'A-Z' 'a-z')" "$(date '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/')" \
        "$level" "$source" "$event" "$(json_str "$message")" "$extra" >> "$ERRLOG"
}

# Микрофон — из строки CallTap «✅ запись идёт: … микрофон «…» → …/<имя>.wav (…)». Имя записи — из current/.session
# (его пишут start и name: после ввода имени клиента файл переименован), у записей прошлых версий — из той же строки.
mic_name() { sed -n 's/.*микрофон «\(.*\)» → .*/\1/p' "$LOG" 2>/dev/null | tail -1; }
log_session() { cat "$CUR/.session" 2>/dev/null || sed -n 's|.*запись идёт: .* → .*/\(.*\)\.wav (.*|\1|p' "$LOG" 2>/dev/null | tail -1; }

# После записи — всё тревожное из журнала CallTap в журнал ошибок. Сам CallTap не трогаем: его пересборка
# сбросила бы разрешения macOS. Каждую запись разбираем один раз (имя последней разобранной — в logs/.checked).
check_capture() {
    local session; session=$(log_session)
    # Разбираем только начавшуюся запись (при неудачном старте разбирать нечего — об этом уже есть start_failed).
    grep -q "запись идёт" "$LOG" 2>/dev/null || return 0
    [ -n "$session" ] && [ "$(cat "$DIR/logs/.checked" 2>/dev/null)" != "$session" ] || return 0
    printf '%s\n' "$session" > "$DIR/logs/.checked"
    # При обычной остановке CallTap пишет «запись остановлена»; если нет — он упал или его убили посреди записи.
    # Кнопка в строке меню замечает это сразу и оставляет метку .died-logged, чтобы не записать дважды.
    if ! grep -q "запись остановлена" "$LOG" && [ ! -f "$CUR/.died-logged" ]; then
        log_event calltap error calltap_died "CallTap завершился сам посреди записи — запись оборвалась" \
            "session=$session" "log=$(tail -n 5 "$LOG")"
    fi
    rm -f "$CUR/.died-logged"
    local line lvl
    grep -E "❌|⚠️" "$LOG" | while IFS= read -r line; do
        case "$line" in *❌*) lvl=error ;; *) lvl=warning ;; esac
        log_event calltap "$lvl" calltap_message "${line#* }" "session=$session" "at=${line%% *}"
    done
    # Молчание всю запись — по строкам уровней, кроме первой (первые секунды AirPods переключаются в режим гарнитуры).
    local levels; levels=$(grep "уровень" "$LOG" | tail -n +2)
    if [ -n "$levels" ]; then
        grep -qvE "микрофон +-inf" <<< "$levels" || log_event calltap warning mic_silent \
            "Микрофон молчал всю запись — ваш голос не записан" "session=$session" "mic=$(mic_name)"
        grep -qvE "собеседник +-inf" <<< "$levels" || log_event calltap warning far_silent \
            "Звук Mac молчал всю запись — голос собеседника не записан" "session=$session"
    fi
    # Отчёты macOS о падениях CallTap и LiveStream за время записи.
    local r src
    find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 \( -name 'CallTap*' -o -name 'LiveStream*' \) \
        -newer "$DIR/logs/.recording-started" 2>/dev/null | while IFS= read -r r; do
        case "$r" in *LiveStream*) src=livestream ;; *) src=calltap ;; esac
        log_event "$src" error crash_report "macOS записала отчёт о падении" "session=$session" "report=$(basename "$r")"
    done
}

# Последние события журнала в читаемом виде (JSON разбирает встроенный в macOS JavaScript).
show_errors() {
    [ -s "$ERRLOG" ] || { echo "Журнал ошибок пуст"; return 0; }
    tail -n "${1:-30}" "$ERRLOG" | osascript -l JavaScript -e '
ObjC.import("Foundation")
const raw = $.NSString.alloc.initWithDataEncoding($.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile, $.NSUTF8StringEncoding).js
const mark = { error: "❌", warning: "⚠️ ", info: "· " }
raw.split("\n").filter(Boolean).map(l => {
    try {
        const e = JSON.parse(l)
        const d = e.details ? Object.entries(e.details).map(([k, v]) => `${k}=${typeof v === "string" ? v.replace(/\n/g, " | ") : JSON.stringify(v)}`).join(", ") : ""
        return `${e.time.slice(0, 19).replace("T", " ")} ${mark[e.level] || e.level} [${e.source}] ${e.message}` +
            (e.session ? ` — «${e.session}»` : "") + (d ? `\n      ${d}` : "")
    } catch (_) { return l }
}).join("\n")'
}

# Имя записи — оно же имя папки и сессии эфира на сервере: ГГГГ-ММ-ДД_ЧЧ-ММ_Имя клиента
# (без имени — только дата и время). Без «/» и «\», не начинается с точки, не длиннее 120 символов.
session_name() {  # $1 — имя клиента, $2 — дата и время начала (по умолчанию сейчас)
    local client="${1:-}"
    client="${client//\//-}"; client="${client//\\/-}"
    client=$(printf '%s' "$client" | sed -E 's/^[[:space:].]+//; s/[[:space:]]+$//')
    client="${client:0:100}"
    local stamp="${2:-$(date '+%Y-%m-%d_%H-%M')}"
    if [ -n "$client" ]; then printf '%s_%s' "$stamp" "$client"; else printf '%s' "$stamp"; fi
}

# Два звонка за одну минуту с тем же именем не должны затирать друг друга (и на сервере это разные разговоры).
unique_name() {
    local name="$1" n=2
    while [ -e "$REC_DIR/$name" ] || [ -e "$REC_DIR/$name.m4a" ] || [ -e "$CUR/$name.wav" ]; do
        name="${1}_${n}"; n=$((n + 1))
    done
    printf '%s' "$name"
}

# POST на сервер с ключом. Ключ идёт заголовком через отдельный поток: его не видно ни в списке процессов, ни в журналах.
api() {  # $1 — путь (/api/…), дальше — аргументы curl
    local path="$1"; shift
    curl -sS --fail-with-body --max-time "${API_TIMEOUT:-15}" -X POST \
        -H @<(printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$TOKEN_FILE")") "$@" "$(server_url)$path"
}

start() {  # $1 — имя клиента или --name-later: запись сразу, имя потом командой name (эфир включится после него)
    local later=0 client="${1:-}"
    if [ "$client" = --name-later ]; then later=1; client=""; fi
    if recording; then echo "Запись уже идёт"; return 0; fi
    [ -x "$BIN" ] || { echo "❌ CallTap не установлен — запустите install.sh"; log_event script error calltap_missing "CallTap не установлен"; exit 1; }
    mkdir -p "$CUR" "$REC_DIR" "$DIR/logs"
    check_capture   # прошлая запись, если её так и не остановили через off (например, CallTap упал)
    local w
    for w in "$CUR"/*.wav; do
        [ -f "$w" ] && log_event script warning leftover_recording \
            "Несохранённая запись прошлого раза — сохранится вместе с новой" "session=$(basename "$w" .wav)" "file=$(basename "$w")"
    done
    : > "$LOG"
    touch "$DIR/logs/.recording-started"
    local stamp name; stamp=$(date '+%Y-%m-%d_%H-%M')
    name=$(unique_name "$(session_name "$client" "$stamp")")
    printf '%s\n' "$name" > "$CUR/.session"
    if [ $later = 1 ]; then printf '%s\n' "$stamp" > "$CUR/.name-pending"; else rm -f "$CUR/.name-pending"; fi
    open -n -g "$APP" --stdout "$LOG" --stderr "$LOG" --args record "$CUR/$name.wav"
    # CallTap может повторить запуск, если AirPods как раз переключаются в режим гарнитуры, — ждём до 10 с.
    for _ in $(seq 1 40); do grep -qE "запись идёт|❌" "$LOG" && break; sleep 0.25; done
    if ! recording || ! grep -q "запись идёт" "$LOG"; then
        echo "❌ Запись не началась:"; cat "$LOG"
        log_event calltap error start_failed "Запись не началась" "session=$name" "log=$(tail -n 15 "$LOG")"
        exit 1
    fi
    echo "✅ Идёт запись: $name"
    log_event script info recording_started "Запись началась" "session=$name" "mic=$(mic_name)" \
        "live=$(live_enabled && echo yes || echo no)" "name_later=$( [ $later = 1 ] && echo yes || echo no)"
    if [ $later = 1 ]; then echo "   имя клиента — командой call-recorder name «Имя»$(live_enabled && echo "; прямой эфир включится после неё")"
    elif live_enabled; then start_live "$name"; fi
}

# Имя клиента для записи, начатой с --name-later (кнопка в строке меню спрашивает его уже во время записи).
# Файл записи переименовывается: CallTap пишет в открытый файл, новое имя ему не мешает. Потом включается «Прямой эфир» —
# уже с этим именем, потому что сервер связывает эфир с записью по имени папки; эфир прочитает запись с самого начала.
# Пустое имя — запись остаётся с датой и временем. --no-live — без эфира (звонок уже кончился).
name_recording() {  # $1 — имя клиента, $2 — --no-live
    local stamp old new
    stamp=$(cat "$CUR/.name-pending" 2>/dev/null); old=$(cat "$CUR/.session" 2>/dev/null)
    if [ -z "$stamp" ] || [ ! -f "$CUR/$old.wav" ]; then echo "❌ Нет записи, которая ждёт имени клиента"; exit 1; fi
    new="$old"
    if [ -n "$(printf '%s' "${1:-}" | tr -d '[:space:]')" ]; then
        new=$(unique_name "$(session_name "$1" "$stamp")")
        if ! mv "$CUR/$old.wav" "$CUR/$new.wav"; then
            echo "❌ Не удалось переименовать запись"
            log_event script error rename_failed "Не удалось дать записи имя клиента" "session=$old" "to=$new"
            exit 1
        fi
        printf '%s\n' "$new" > "$CUR/.session"
        log_event script info recording_named "Записи дано имя клиента" "session=$new" "from=$old"
        echo "✅ Запись: $new"
    fi
    rm -f "$CUR/.name-pending"
    if live_enabled && [ "${2:-}" != --no-live ] && recording; then start_live "$new"; fi
}

# Прямой эфир — отдельный процесс LiveStream: читает тот же WAV и шлёт куски на сервер. Если он упадёт
# или сети нет, запись идёт как обычно.
start_live() {
    local name="$1"
    if ! server_ready; then
        echo "⚠️  Прямой эфир не включён: не заданы адрес сервера или ключ"
        log_event livestream warning live_not_started "Прямой эфир не включён: не заданы адрес сервера или ключ" "session=$name"
        return 0
    fi
    if [ ! -x "$LIVE_BIN" ]; then
        echo "⚠️  Прямой эфир не включён: LiveStream не установлен — запустите install.sh"
        log_event livestream warning live_not_started "Прямой эфир не включён: LiveStream не установлен" "session=$name"
        return 0
    fi
    printf 'wait\n' > "$DIR/logs/live-status"
    printf '%s\n' "$name" > "$CUR/.live-session"
    nohup "$LIVE_BIN" "$CUR/$name.wav" "$name" "$(server_url)" >> "$DIR/logs/live.log" 2>&1 &
    echo "📡 Прямой эфир включён"
}

# Остановить LiveStream (он дочитает хвост и отправит последний кусок) и сообщить серверу, что разговор окончен.
stop_live() {
    # LiveStream сам выходит только по ответу сервера 409/403 (и пишет «эфир завершён»); иначе он упал.
    if [ -f "$CUR/.live-session" ] && ! live_running && ! tail -n 1 "$DIR/logs/live.log" 2>/dev/null | grep -q "эфир завершён"; then
        log_event livestream error live_died "Прямой эфир оборвался сам посреди записи" "session=$(cat "$CUR/.live-session")" \
            "log=$(tail -n 5 "$DIR/logs/live.log" 2>/dev/null)"
    fi
    if live_running; then
        pkill -TERM -f "$LIVE_BIN "
        for _ in $(seq 1 80); do live_running || break; sleep 0.1; done
    fi
    local name; name=$(cat "$CUR/.live-session" 2>/dev/null) || return 0
    rm -f "$CUR/.live-session"
    [ -n "$name" ] && server_ready || return 0
    local code; code=$(API_TIMEOUT=10 api /api/live/end --url-query "session=$name" -o /dev/null -w '%{http_code}' 2>/dev/null)
    if [ "$code" = 200 ]; then echo "📡 Эфир завершён"
    else
        echo "⚠️  Сервер не подтвердил конец эфира (закроет его сам через 2 минуты)"
        log_event livestream warning live_end_failed "Сервер не подтвердил конец эфира" "session=$name" "http=${code:-000}"
    fi
}

stop() {
    if recording; then
        pkill -TERM -f "$BIN record"
        for _ in $(seq 1 40); do recording || break; sleep 0.25; done
    fi
    stop_live
    check_capture
    rm -f "$CUR/.name-pending"   # имя так и не ввели — запись сохранится с датой и временем
    local found=0 empty=0 w base out gf gm dur ferr="$DIR/logs/ffmpeg-last.log"
    for w in "$CUR"/*.wav; do
        [ -f "$w" ] || continue
        found=1
        base=$(basename "$w" .wav)
        dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$w" 2>/dev/null | cut -d. -f1)
        if ! [ "${dur:-0}" -ge 1 ] 2>/dev/null; then
            rm -f "$w"; empty=1
            echo "⚠️ Запись «${base}» пустая: звук не поступал. Начните запись ещё раз."
            log_event script error empty_recording "Запись пустая: звук не поступал" "session=$base"
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
                -map "[far]" -c:a aac -b:a 96k -metadata title="$base — собеседник" "$out/$base — собеседник.m4a" 2>"$ferr" && ok=1
        else
            saved="$REC_DIR/$base.m4a"
            target="$saved"
            ffmpeg -v error -y -i "$w" -filter_complex "$sides;$mix;[f2]anullsink;[m2]anullsink" \
                -map "[mix]" -c:a aac -b:a 128k -metadata title="$base" "$saved" 2>"$ferr" && ok=1
        fi
        if [ $ok = 1 ]; then
            rm -f "$w"
            local secs; secs=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$saved" | cut -d. -f1)
            echo "✅ Запись сохранена ($((secs / 60)) мин $((secs % 60)) с):"
            log_event script info recording_saved "Запись сохранена" "session=$base" "seconds=$secs" \
                "split=$(split_enabled && echo yes || echo no)"
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
            cat "$ferr" >&2
            echo "❌ Не удалось преобразовать запись, исходный файл оставлен: $w"
            log_event script error convert_failed "Не удалось преобразовать запись, исходный WAV оставлен" "session=$base" \
                "ffmpeg=$(tail -n 5 "$ferr")"
            exit 1
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
            upload_call "$folder" "$remote" 900 /api/inbox --url-query "file=$remote" \
                -H 'Content-Type: application/octet-stream' -H 'Expect:' -T "$f" --retry-delay 5 || ok=0
        done
    else
        upload_call "$folder" mix.m4a 900 /api/inbox --url-query "file=mix.m4a" \
            -H 'Content-Type: application/octet-stream' -H 'Expect:' -T "$src" --retry-delay 5 || ok=0
    fi
    if [ $ok = 1 ] && upload_call "$folder" .ready 30 /api/inbox/done; then
        printf 'ok\n%s\n' "$src" > "$UPLOADS/$folder"
        echo "   ✅ отправлено"
    else
        printf 'failed\n%s\n' "$src" > "$UPLOADS/$folder"
        echo "   ❌ не отправлено — повторить: call-recorder upload"
        return 1
    fi
}

# Один запрос отправки с повторами; при неудаче — строка в выводе и событие в журнале с кодом ответа,
# текстом ошибки curl и началом ответа сервера.
upload_call() {  # $1 — папка на сервере, $2 — что отправляем (для журнала), $3 — тайм-аут, $4 — путь API, дальше — аргументы curl
    local folder="$1" what="$2" timeout="$3" path="$4" code rc err body; shift 4
    err=$(mktemp); body=$(mktemp)
    code=$(API_TIMEOUT=$timeout api "$path" --url-query "folder=$folder" "$@" --retry 3 --retry-all-errors \
        -o "$body" -w '%{http_code}' 2>"$err")
    rc=$?
    if [ $rc != 0 ]; then
        echo "   ❌ $what не отправлен"
        # С повторами curl печатает код каждой попытки подряд — берём последний.
        log_event upload error upload_failed "Запись не отправлена на сервер: $what" "session=$folder" "file=$what" \
            "http=${code: -3}" "curl=$(tail -n 2 "$err")" "response=$(head -c 300 "$body")"
    fi
    rm -f "$err" "$body"
    return $rc
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

# --- Журнал ошибок → сервер (POST /api/logs, протокол docs/LOGS.md в CRM) ---------------------------------
# Докуда журнал отправлен, помнит logs/send-logs.pos. По номеру файла видно, что журнал успел смениться
# (errors.jsonl → errors.jsonl.1): тогда сначала досылается хвост прошлого, потом новый с начала.
# Повтор пачки безопасен: сервер не пишет второй раз событие с уже известным id.

send_status() {  # $1 — ok | retry | forbidden, $2 — причина. Время первой неудачи подряд сохраняется: по нему меню решает, пора ли тревожить.
    local since; since=$(date +%s)
    if [ "$1" != ok ] && [ "$(head -1 "$SEND_STATUS" 2>/dev/null)" = "$1" ]; then since=$(sed -n 2p "$SEND_STATUS"); fi
    printf '%s\n%s\n%s\n' "$1" "$since" "${2:-}" > "$SEND_STATUS"
}

json_num() { plutil -extract "$1" raw -o - "$2" 2>/dev/null | grep -E '^[0-9]+$' || echo 0; }   # $1 — поле ответа, $2 — файл

# Строки, которые сервер отверг (не примет никогда), — одним событием logs_rejected; оно уйдёт следующей пачкой.
# Отказы по самим logs_rejected не записываем, чтобы не зациклиться.
note_rejected() {  # $1 — пачка, $2 — ответ сервера
    local n i k line ev id list="" count=0
    n=$(json_num rejected "$2")
    for ((i = 0; i < n; i++)); do
        k=$(json_num "rejected.$i.line" "$2")
        line=$(sed -n "${k}p" "$1")
        ev=$(printf '%s' "$line" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')
        id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
        [ "$ev" = logs_rejected ] && continue
        count=$((count + 1))
        # «calltap_died 2f1fa41f-…: time не ISO 8601»; у строки без кода события — её номер в пачке.
        [ $count -le 10 ] && list+="${list:+$'\n'}${ev:-строка $k}${id:+ $id}: $(plutil -extract "rejected.$i.error" raw -o - "$2" 2>/dev/null)"
    done
    [ $count = 0 ] || log_event script warning logs_rejected "Сервер не принял события журнала: $count" "count=$count" "rejected=$list"
}

# Отправить новые строки журнала пачками до 500 строк и 1 МБ. Только целые строки: последнюю могут ещё дописывать.
# Ответ 200 — пачка ушла; 413 — пачку пополам; 403 — ключ не подходит; сеть, 429, 5xx и прочее — повторить позже.
send_logs() {  # $1 — --auto (кнопка в строке меню раз в 30 с): тихо, после неудачи не чаще раза в 5 минут, после 403 — только с новым ключом
    local auto=0
    if [ "${1:-}" = --auto ]; then auto=1; fi
    if ! server_ready; then
        [ $auto = 1 ] || echo "❌ Не заданы адрес сервера или ключ"
        return $((1 - auto))
    fi
    mkdir -p "$DIR/logs"
    if [ $auto = 1 ]; then
        local state; state=$(head -1 "$SEND_STATUS" 2>/dev/null)
        if [ "$state" = forbidden ] && ! [ "$TOKEN_FILE" -nt "$SEND_STATUS" ] && ! [ "$SETTINGS" -nt "$SEND_STATUS" ]; then return 0; fi
        if [ "$state" = retry ] && [ $(($(date +%s) - $(stat -f%m "$SEND_STATUS"))) -lt 300 ]; then return 0; fi
        exec >> "$DIR/logs/send-logs.log" 2>&1
    fi
    # Один отправитель за раз: из меню — сразу выходим (проверит снова через 30 с), после записи — ждём до минуты.
    local lock="$DIR/logs/.send-logs.lock" tries=0 rc
    until shlock -f "$lock" -p $$; do
        tries=$((tries + 1))
        if [ $auto = 1 ] || [ $tries -ge 60 ]; then return 0; fi
        sleep 1
    done
    # Журнал отправки не растёт бесконечно: больше 1 МБ — остаются последние 2000 строк (на месте: файл открыт на дописывание).
    if [ "$(stat -f%z "$DIR/logs/send-logs.log" 2>/dev/null || echo 0)" -gt 1000000 ]; then
        local keep; keep=$(tail -n 2000 "$DIR/logs/send-logs.log"); printf '%s\n' "$keep" > "$DIR/logs/send-logs.log"
    fi
    send_logs_locked $auto; rc=$?
    rm -f "$lock"
    return $rc
}

send_logs_locked() {
    local auto=$1 max=500 sent=0 dup=0 posted=0 rc=0 why="" round pos ino off file fino size lines n bytes code
    local raw batch resp err stamp=""
    raw=$(mktemp); batch=$(mktemp); resp=$(mktemp); err=$(mktemp)
    for round in $(seq 1 200); do
        pos=$(cat "$SENT_POS" 2>/dev/null); ino="${pos%% *}"; off="${pos##* }"
        [[ "$off" =~ ^[0-9]+$ ]] || off=0
        if [ -z "$pos" ] && [ -f "$ERRLOG.1" ]; then   # первая отправка — сначала прошлый журнал
            printf '%s 0\n' "$(stat -f%i "$ERRLOG.1")" > "$SENT_POS"; continue
        fi
        if [ -f "$ERRLOG.1" ] && [ "$(stat -f%i "$ERRLOG.1")" = "$ino" ]; then file="$ERRLOG.1"
        elif [ -f "$ERRLOG" ]; then
            file="$ERRLOG"
            [ "$(stat -f%i "$file")" = "$ino" ] || off=0   # журнал новый
        else break
        fi
        fino=$(stat -f%i "$file"); size=$(stat -f%z "$file")
        [ "$off" -le "$size" ] || off=0
        if [ "$off" -ge "$size" ]; then
            [ "$file" = "$ERRLOG.1" ] || break   # всё отправлено
            printf '%s 0\n' "$(stat -f%i "$ERRLOG" 2>/dev/null || echo 0)" > "$SENT_POS"; continue   # дальше новый журнал
        fi
        tail -c "+$((off + 1))" "$file" | head -c 1000000 > "$raw"
        [ "$(stat -f%i "$file" 2>/dev/null)" = "$fino" ] || continue   # журнал сменился, пока читали, — заново
        lines=$(($(tr -cd '\n' < "$raw" | wc -c)))
        if [ $lines = 0 ]; then
            # Нет ни одной целой строки. В errors.jsonl последнюю ещё дописывают — подождём; в прошлом журнале
            # или строка длиннее 1 МБ — это мусор, пропускаем, иначе встанет вся очередь.
            if [ "$file" = "$ERRLOG.1" ] || [ $(($(wc -c < "$raw"))) -ge 1000000 ]; then
                printf '%s %s\n' "$fino" $((off + $(wc -c < "$raw"))) > "$SENT_POS"; continue
            fi
            break
        fi
        n=$((lines < max ? lines : max))
        head -n $n "$raw" > "$batch"
        bytes=$(($(wc -c < "$batch")))
        code=$(API_TIMEOUT=30 api /api/logs -H 'Content-Type: application/x-ndjson' -H 'Expect:' --data-binary "@$batch" \
            --retry 2 -o "$resp" -w '%{http_code}' 2>"$err")
        code="${code: -3}"   # с повторами curl печатает код каждой попытки подряд
        # 200 без {"ok":true} — это не наш сервер (например, страница-заглушка): события не считаем отправленными.
        if [ "$code" = 200 ] && [ "$(plutil -extract ok raw -o - "$resp" 2>/dev/null)" != true ]; then code=bad; fi
        case "$code" in
            200)
                printf '%s %s\n' "$fino" $((off + bytes)) > "$SENT_POS"
                posted=1
                sent=$((sent + $(json_num accepted "$resp"))); dup=$((dup + $(json_num duplicates "$resp")))
                note_rejected "$batch" "$resp" ;;
            413)
                if [ $n -gt 1 ]; then max=$((n / 2)); continue; fi
                # Сервер не берёт даже одну эту строку — не возьмёт никогда.
                printf '%s %s\n' "$fino" $((off + bytes)) > "$SENT_POS"
                printf '{"rejected":[{"line":1,"error":"сервер ответил 413: строка слишком большая"}]}' > "$resp"
                note_rejected "$batch" "$resp" ;;
            403) why="сервер не принял ключ"; send_status forbidden "$why"; rc=1; break ;;
            *)
                if [ "${code:-000}" = 000 ]; then why="нет связи: $(tail -n 1 "$err" | sed 's/^curl: //')"
                elif [ "$code" = bad ]; then why="непонятный ответ сервера: $(head -c 100 "$resp")"
                else why="сервер ответил $code"; fi
                send_status retry "$why"; rc=1; break ;;
        esac
    done
    rm -f "$raw" "$batch" "$resp" "$err"
    if [ $rc = 0 ] && [ $posted = 1 ]; then send_status ok; fi
    [ -t 1 ] || stamp="$(date '+%F %T') "
    if [ "$(head -1 "$SEND_STATUS" 2>/dev/null)" = forbidden ] && [ $rc != 0 ]; then
        echo "${stamp}❌ Журнал ошибок не отправлен: сервер не принял ключ — проверьте его (call-recorder token)"
    elif [ $rc != 0 ]; then
        echo "${stamp}⚠️  Журнал ошибок не отправлен ($why) — повторю позже"
    elif [ $posted = 1 ]; then
        echo "${stamp}✅ Журнал ошибок отправлен на сервер: новых событий $sent$( [ $dup = 0 ] || echo ", уже были там $dup")"
    elif [ $auto = 0 ]; then
        echo "${stamp}Журнал ошибок: новых событий нет"
    fi
    return $rc
}

# После записи, остановки и отправки записи — журнал на сервер в фоне, не задерживая команду
# (кнопка в строке меню вдобавок проверяет его раз в 30 с).
send_logs_later() {
    server_ready && ! journal_sent || return 0
    nohup bash "$DIR/call-recorder.sh" send-logs >> "$DIR/logs/send-logs.log" 2>&1 &
}

# Журнал отправлен до конца: позиция отправки — конец errors.jsonl (или журнал пуст).
journal_sent() { [ "$(cat "$SENT_POS" 2>/dev/null)" = "$(stat -f'%i %z' "$ERRLOG" 2>/dev/null)" ] || [ ! -s "$ERRLOG" ]; }

# Состояние отправки журнала одной строкой — для call-recorder status.
logs_state() {
    server_ready || { echo "не отправляется — не заданы адрес сервера или ключ"; return; }
    case "$(head -1 "$SEND_STATUS" 2>/dev/null)" in
        forbidden) echo "не отправляется — сервер не принял ключ" ;;
        retry) echo "не отправлен с $(date -r "$(sed -n 2p "$SEND_STATUS")" '+%d.%m %H:%M') ($(sed -n 3p "$SEND_STATUS")), повтор раз в 5 минут" ;;
        *) if journal_sent; then echo "отправлен"; else echo "есть новые события — уйдут в течение минуты"; fi ;;
    esac
}

status() {
    if recording; then
        echo "Идёт запись «$(log_session)» — $(grep "уровень" "$LOG" | tail -1)"
        if [ -f "$CUR/.name-pending" ]; then echo "Имя клиента ещё не введено: call-recorder name «Имя»"; fi
        if mic_silent; then echo "⚠️  Микрофон молчит: разрешите CallTap доступ к микрофону (Системные настройки → Конфиденциальность и безопасность → Микрофон)"; fi
        if live_running; then echo "📡 Прямой эфир: $(cat "$DIR/logs/live-status" 2>/dev/null)"; fi
    else
        echo "Запись не идёт"
    fi
    if split_enabled; then echo "Голоса сохраняются отдельно: оба / я / собеседник"; else echo "Сохраняется один файл с обоими голосами"; fi
    local srv; srv=$(server_url)
    echo "Сервер: ${srv:-не задан}, $( [ -s "$TOKEN_FILE" ] && echo "ключ задан" || echo "ключ не задан")"
    if live_enabled; then echo "Прямой эфир: включён"; else echo "Прямой эфир: выключен"; fi
    echo "Журнал ошибок на сервере: $(logs_state)"
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
    on|start) trap send_logs_later EXIT; start "${2:-}" ;;
    name) trap send_logs_later EXIT; name_recording "${2:-}" "${3:-}" ;;
    off|stop) trap send_logs_later EXIT; stop ;;
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
    upload) trap send_logs_later EXIT; upload_failed ;;
    upload-one) trap send_logs_later EXIT; upload_one "${2:-}" "${3:-}" ;;
    errors) show_errors "${2:-30}" ;;
    send-logs) send_logs "${2:-}" ;;
    log-event) shift; log_event "$@" ;;   # для кнопки в строке меню и тестов
    *) echo "использование: call-recorder on [\"Имя клиента\" | --name-later] | name [\"Имя клиента\"] | off | status | split on|off | live on|off | server <адрес> | token | upload | errors [N] | send-logs"; exit 2 ;;
esac
