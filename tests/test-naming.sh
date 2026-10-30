#!/bin/bash
# Проверка записи «сначала запись, потом имя» (кнопка в строке меню: on --name-later, затем name) на сервере-имитаторе:
# имя клиента вводят через 3 с — файл записи переименовывается, пока в него пишут, «Прямой эфир» идёт уже под именем
# с клиентом и с самого начала записи, сохранённая запись и папка на сервере — с тем же именем.
# Вместо CallTap — заглушка, вместо звука — растущий WAV, как у CallTap. Настоящие настройки и ключ не трогаются.
#   bash tests/test-naming.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/naming-test.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null || true; pkill -f "$T/app/CallTap.app" 2>/dev/null || true; rm -rf "$T"' EXIT
PORT=$((20000 + RANDOM % 20000))
fail() { echo "❌ $*"; exit 1; }

A="$T/app"; CUR="$A/current"; LOG="$A/logs/calltap.log"
mkdir -p "$A/logs" "$CUR" "$A/CallTap.app/Contents/MacOS" "$T/rec"
cp "$ROOT/call-recorder.sh" "$A/call-recorder.sh"
printf 'server=http://127.0.0.1:%s\nlive=yes\n' "$PORT" > "$A/settings"
printf 'test-token\n' > "$A/inbox-token"
export CALL_RECORDER_DIR="$A" CALL_RECORDER_REC_DIR="$T/rec"
cr() { bash "$A/call-recorder.sh" "$@"; }
journal() { python3 -I -c 'import json, sys; [print(json.dumps(json.loads(l), ensure_ascii=False)) for l in open(sys.argv[1], encoding="utf-8")]' "$A/logs/errors.jsonl"; }

echo "▶︎ сборка LiveStream"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$A/LiveStream" "$ROOT/src/LiveStream/main.swift" 2>/dev/null
# Заглушка CallTap: видна как «…/CallTap record …», на TERM пишет в журнал «запись остановлена», как настоящий.
cat > "$A/CallTap.app/Contents/MacOS/CallTap" <<STUB
#!/bin/bash
trap 'echo "\$(date +%T) запись остановлена" >> "$LOG"; exit 0' TERM
while true; do sleep 0.2; done
STUB
chmod +x "$A/CallTap.app/Contents/MacOS/CallTap"
ffmpeg -v error -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=6" \
       -filter_complex "[0:a][1:a]join=inputs=2:channel_layout=stereo" -c:a pcm_s16le "$T/source.wav"

echo "▶︎ name без записи, которая ждёт имени, — отказ"
cr name "Кто-то" > "$T/out" 2>&1 && fail "name без записи должен не удаться"
grep -q "Нет записи, которая ждёт имени" "$T/out" || fail "вывод: $(cat "$T/out")"
echo "   ✓"

echo "▶︎ запись идёт без имени, через 3 с вводят имя клиента"
python3 -I "$ROOT/tests/live_mock_server.py" --port "$PORT" --out "$T/srv" & srv=$!; sleep 0.5
stamp="2026-10-30_16-17"; name="${stamp}_Эдгар Пук"
mkdir -p "$T/rec/$name"   # такая запись уже есть — новая должна получить «_2»
printf '%s\n' "$stamp" > "$CUR/.session"; printf '%s\n' "$stamp" > "$CUR/.name-pending"
echo "16:17:07 ✅ запись идёт: собеседник (звук Mac) + микрофон «AirPods» → $CUR/$stamp.wav (rate=48000)" > "$LOG"
touch "$A/logs/.recording-started"
"$A/CallTap.app/Contents/MacOS/CallTap" record "$CUR/$stamp.wav" & 
# Пишет WAV порциями по 0,1 с, как CallTap: файл открыт всё время, переименование ему не мешает.
python3 -I - "$T/source.wav" "$CUR/$stamp.wav" <<'PY' &
import sys, time
data = open(sys.argv[1], "rb").read()
step = 48000 * 4 // 10
with open(sys.argv[2], "wb") as f:
    f.write(data[:44]); f.flush()
    for i in range(44, len(data), step):
        f.write(data[i:i + step]); f.flush(); time.sleep(0.1)
PY
grower=$!
sleep 3
cr name "Эдгар Пук" > "$T/out" 2>&1 || fail "name: $(cat "$T/out")"
[ "$(cat "$CUR/.session")" = "${name}_2" ] && [ -f "$CUR/${name}_2.wav" ] && [ ! -e "$CUR/$stamp.wav" ] && [ ! -e "$CUR/.name-pending" ] \
    || fail "после name: $(ls -a "$CUR"), session=$(cat "$CUR/.session")"
echo "   файл переименован в «${name}_2» (имя «${name}» уже занято) ✓"
wait $grower; sleep 1
cr off > "$T/off.out" 2>&1 || fail "off: $(cat "$T/off.out")"
for _ in $(seq 1 40); do [ -f "$T/srv/inbox/${name}_2/.ready" ] && break; sleep 0.25; done
kill $srv

sessions=$(grep '^/api/live/chunk' "$T/srv/requests.log" | cut -d' ' -f6- | sed 's/ -$//' | sort -u)   # имя — между кодом и «-»
[ "$sessions" = "${name}_2" ] || fail "эфир шёл под именем: «${sessions}»"
me=$(stat -f%z "$T/srv/me.pcm"); secs=$(awk -v b="$me" 'BEGIN { printf "%.1f", b / 32000 }')   # 16 кГц × 2 байта
[ "$me" -ge $((32000 * 55 / 10)) ] || fail "в эфир дошло $secs с из 6 — начало потеряно"
grep -q "^/api/live/end .* ${name}_2" "$T/srv/requests.log" || fail "нет конца эфира под новым именем"
echo "   эфир — под именем с клиентом, с начала записи: $secs с из 6 ✓"
ls "$T/rec/${name}_2/" | grep -q "${name}_2 — оба голоса.m4a" || fail "сохранено: $(ls "$T/rec")"
[ -f "$T/srv/inbox/${name}_2/.ready" ] && [ -f "$T/srv/inbox/${name}_2/me.m4a" ] || fail "на сервер не пришло: $(ls -R "$T/srv/inbox")"
echo "   сохранено и отправлено как «${name}_2» ✓"
journal > "$T/j"
python3 -I - "$T/j" "$stamp" "${name}_2" <<'PY' || exit 1
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
names = [e["event"] for e in ev]
assert "calltap_died" not in names, names
n = next(e for e in ev if e["event"] == "recording_named")
assert n["session"] == sys.argv[3] and n["details"]["from"] == sys.argv[2], n
for code in ("live_summary", "recording_saved"):
    e = next(e for e in ev if e["event"] == code)
    assert e["session"] == sys.argv[3], e
PY
echo "   журнал: recording_named «${stamp}» → «${name}_2», эфир и сохранение — под новым именем ✓"

echo "▶︎ пустое имя — запись остаётся с датой и временем"
stamp2="2026-10-30_16-40"
printf '%s\n' "$stamp2" > "$CUR/.session"; printf '%s\n' "$stamp2" > "$CUR/.name-pending"
cp "$T/source.wav" "$CUR/$stamp2.wav"
cr name "  " > "$T/out" 2>&1 || fail "name с пустым именем: $(cat "$T/out")"
[ -f "$CUR/$stamp2.wav" ] && [ ! -e "$CUR/.name-pending" ] && [ "$(cat "$CUR/.session")" = "$stamp2" ] || fail "после пустого имени: $(ls -a "$CUR")"
rm -f "$CUR/$stamp2.wav"
echo "   ✓"

echo "▶︎ запись не началась — после неё нет ложного «CallTap упал»"
: > "$A/logs/errors.jsonl"; rm -f "$A/logs/.checked"
printf '%s\n' "2026-10-30_16-50" > "$CUR/.session"
echo "16:50:01 ❌ микрофон не найден" > "$LOG"
cr off > /dev/null 2>&1 || true
[ ! -s "$A/logs/errors.jsonl" ] || fail "лишние события: $(cat "$A/logs/errors.jsonl")"
echo "   ✓"

grep -rqs "test-token" "$A/logs" && fail "ключ попал в журналы"
echo "✅ Имя клиента после начала записи: все проверки пройдены"
