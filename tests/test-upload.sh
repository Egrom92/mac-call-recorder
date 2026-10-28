#!/bin/bash
# Проверка отправки записи на сервер (call-recorder.sh upload-one / upload) на локальном сервере-имитаторе.
#   bash tests/test-upload.sh
# Настоящие настройки и ключ не трогаются: всё в отдельной папке через CALL_RECORDER_DIR.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/upload-test.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$T"' EXIT
PORT=$((20000 + RANDOM % 20000))
fail() { echo "❌ $*"; exit 1; }

mkdir -p "$T/app"
cp "$ROOT/call-recorder.sh" "$T/app/call-recorder.sh"
printf 'server=http://127.0.0.1:%s/\n' "$PORT" > "$T/app/settings"
printf 'test-token\n' > "$T/app/inbox-token"
export CALL_RECORDER_DIR="$T/app"

name="2026-10-28_18-30_Эрик Эглиенс"
rec="$T/rec/$name"; mkdir -p "$rec"
for part in "я" "собеседник" "оба голоса"; do
    ffmpeg -v error -f lavfi -i "sine=frequency=440:duration=1" -c:a aac "$rec/$name — $part.m4a"
done

echo "▶︎ имя записи из имени клиента"
got=$(bash -c 'source <(sed -n "/^session_name()/,/^}/p" "$1"); session_name " ../Эрик/Эглиенс "' _ "$ROOT/call-recorder.sh")
[[ "$got" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}_-Эрик-Эглиенс$ ]] || fail "имя: «${got}»"
echo "   «${got}» ✓"

echo "▶︎ случай 1: сервер работает"
python3 -I "$ROOT/tests/live_mock_server.py" --port "$PORT" --out "$T/srv1" & srv=$!; sleep 0.5
bash "$T/app/call-recorder.sh" upload-one "$rec" "$name" > "$T/up1.log" 2>&1 || fail "отправка не удалась: $(cat "$T/up1.log")"
kill $srv
dst="$T/srv1/inbox/$name"
for pair in "я:me" "собеседник:them" "оба голоса:mix"; do
    cmp -s "$rec/$name — ${pair%%:*}.m4a" "$dst/${pair##*:}.m4a" || fail "${pair##*:}.m4a не совпадает или не пришёл"
done
[ -f "$dst/.ready" ] || fail "нет пометки готовности"
[ "$(tail -1 "$T/srv1/requests.log" | cut -d' ' -f1)" = "/api/inbox/done" ] || fail "пометка готовности ушла не последней"
[ "$(head -1 "$T/app/uploads/$name")" = "ok" ] || fail "состояние не ok"
grep -q "test-token" "$T/up1.log" "$T/app/uploads/$name" && fail "ключ попал в журнал"
echo "   me/them/mix пришли целыми в «${name}», .ready последним, ключа в журнале нет ✓"

echo "▶︎ случай 2: сервер недоступен, потом повтор"
python3 -I "$ROOT/tests/live_mock_server.py" --port "$PORT" --out "$T/srv2" --fail-inbox & srv=$!; sleep 0.5
bash "$T/app/call-recorder.sh" upload-one "$rec" "$name" > "$T/up2.log" 2>&1 && fail "отправка должна была не удаться"
kill $srv; sleep 0.3
[ "$(head -1 "$T/app/uploads/$name")" = "failed" ] || fail "состояние не failed"
[ -f "$T/srv2/inbox/$name/.ready" ] && fail "пометка готовности поставлена, хотя файлы не дошли"
python3 -I "$ROOT/tests/live_mock_server.py" --port "$PORT" --out "$T/srv3" & srv=$!; sleep 0.5
bash "$T/app/call-recorder.sh" upload > "$T/up3.log" 2>&1 || fail "повтор не удался: $(cat "$T/up3.log")"
kill $srv
[ -f "$T/srv3/inbox/$name/.ready" ] && [ "$(head -1 "$T/app/uploads/$name")" = "ok" ] || fail "повтор не дослал запись"
echo "   при сбое — «не отправлено» без пометки готовности, «call-recorder upload» дослал ✓"

echo "✅ Отправка записей: все проверки пройдены"
