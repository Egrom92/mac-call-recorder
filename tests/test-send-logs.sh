#!/bin/bash
# Проверка отправки журнала ошибок на сервер (call-recorder.sh send-logs) на локальном сервере-имитаторе:
# пачки по 500 строк, недописанная строка, отвергнутая строка, 503 и пауза, нет связи, 403 и смена ключа, 413,
# смена журнала (errors.jsonl → errors.jsonl.1), ответ не от нашего сервера, отправка сама после «off».
#   bash tests/test-send-logs.sh
# Настоящие настройки и ключ не трогаются: всё в отдельной папке через CALL_RECORDER_DIR.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/send-logs-test.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$T"' EXIT
PORT=$((20000 + RANDOM % 20000))
fail() { echo "❌ $*"; exit 1; }

mkdir -p "$T/app/logs"
cp "$ROOT/call-recorder.sh" "$T/app/call-recorder.sh"
printf 'server=http://127.0.0.1:%s/\n' "$PORT" > "$T/app/settings"
printf 'test-token\n' > "$T/app/inbox-token"
export CALL_RECORDER_DIR="$T/app"
J="$T/app/logs/errors.jsonl"
STATUS="$T/app/logs/send-logs.status"
cr() { bash "$T/app/call-recorder.sh" "$@"; }
ev() { cr log-event script info "$1" "Проверка $1" "session=2026-10-30_10-00_Тест"; }
srv=""
server() {  # $1 — папка имитатора, дальше — его ключи
    if [ -n "$srv" ]; then kill "$srv"; wait "$srv" 2>/dev/null || true; fi
    python3 -I "$ROOT/tests/live_mock_server.py" --port "$PORT" --out "$@" & srv=$!; sleep 0.5
}
stop_server() { kill "$srv"; wait "$srv" 2>/dev/null || true; srv=""; }
received() { [ -f "$T/srv/logs.jsonl" ] && python3 -I -c 'import json, sys; print(" ".join(json.loads(l)["event"] for l in open(sys.argv[1], encoding="utf-8")))' "$T/srv/logs.jsonl"; }
reqs() { local n; n=$(grep -c '^/api/logs' "$T/srv/requests.log" 2>/dev/null) || true; echo "${n:-0}"; }
all_sent() { [ "$(cat "$T/app/logs/send-logs.pos")" = "$(stat -f'%i %z' "$J")" ]; }
ago() { date -v-"$1" '+%Y%m%d%H%M.%S'; }

echo "▶︎ пачка уходит; испорченную строку сервер отвергает — о ней событие logs_rejected, и оно уходит следом"
ev a_one; ev a_two
printf 'не JSON\n' >> "$J"
ev a_three
server "$T/srv"
cr send-logs > "$T/out" || fail "send-logs: $(cat "$T/out")"
grep -q "✅ Журнал ошибок отправлен на сервер: новых событий 4" "$T/out" || fail "вывод: $(cat "$T/out")"
[ "$(received)" = "a_one a_two a_three logs_rejected" ] || fail "сервер получил: $(received)"
python3 -I - "$J" <<'PY' || exit 1
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.startswith("{")]
r = next(e for e in ev if e["event"] == "logs_rejected")
assert r["level"] == "warning" and r["details"]["count"] == "1" and r["details"]["rejected"] == "строка 3: не JSON или нет id", r
PY
all_sent || fail "позиция отправки не в конце журнала"
[ "$(head -1 "$STATUS")" = ok ] || fail "состояние не ok"
echo "   4 события + logs_rejected за один запуск, позиция в конце журнала ✓"

echo "▶︎ новых событий нет — запроса нет"
before=$(reqs)
cr send-logs > "$T/out"
grep -q "новых событий нет" "$T/out" && [ "$(reqs)" = "$before" ] || fail "лишний запрос или вывод: $(cat "$T/out")"
echo "   ✓"

echo "▶︎ недописанная строка ждёт, пока её допишут"
full='{"id":"partial-line-0001","time":"2026-10-30T10:00:00+02:00","level":"info","source":"script","event":"a_partial","message":"дописана позже"}'
printf '%s' "${full:0:40}" >> "$J"
before=$(reqs)
cr send-logs > "$T/out"
[ "$(reqs)" = "$before" ] || fail "недописанная строка ушла на сервер"
printf '%s\n' "${full:40}" >> "$J"
cr send-logs > /dev/null || fail "дописанная строка не ушла"
[ "$(received | awk '{print $NF}')" = a_partial ] && all_sent || fail "дописанная строка не дошла: $(received)"
echo "   ✓"

echo "▶︎ короткий сбой 503 — curl повторяет сам"
server "$T/srv" --logs-fail 1
ev b_blip
cr send-logs > /dev/null || fail "не дослал после одного 503"
[ "$(received | awk '{print $NF}')" = b_blip ] || fail "не дошло: $(received)"
echo "   ✓"

echo "▶︎ сервер отвечает 503 — повтор позже; --auto выжидает 5 минут"
server "$T/srv" --logs-fail 3
ev b_one
cr send-logs > "$T/out" && fail "отправка должна была не удаться"
grep -q "сервер ответил 503" "$T/out" && [ "$(head -1 "$STATUS")" = retry ] || fail "вывод: $(cat "$T/out"), состояние: $(head -1 "$STATUS")"
all_sent && fail "позиция сдвинулась, хотя пачка не ушла"
before=$(reqs)
cr send-logs --auto
[ "$(reqs)" = "$before" ] || fail "--auto не выждал паузу"
touch -t "$(ago 6M)" "$STATUS"
cr send-logs --auto
[ "$(received | awk '{print $NF}')" = b_one ] && all_sent && [ "$(head -1 "$STATUS")" = ok ] || fail "после паузы не дослал: $(received)"
echo "   ✓"

echo "▶︎ сервер недоступен — «нет связи», потом досылается"
stop_server
ev c_one
cr send-logs > "$T/out" && fail "отправка должна была не удаться"
grep -q "нет связи" "$STATUS" || fail "причина: $(cat "$STATUS")"
server "$T/srv"
touch -t "$(ago 6M)" "$STATUS"
cr send-logs --auto
[ "$(received | awk '{print $NF}')" = c_one ] && all_sent || fail "не дослал: $(received)"
echo "   ✓"

echo "▶︎ 403 — не повторяет, пока не сменят ключ"
printf 'wrong-token\n' > "$T/app/inbox-token"; touch -t "$(ago 2M)" "$T/app/inbox-token" "$T/app/settings"
ev d_one
cr send-logs > "$T/out" && fail "с неверным ключом должно не удаться"
grep -q "сервер не принял ключ" "$T/out" && [ "$(head -1 "$STATUS")" = forbidden ] || fail "вывод: $(cat "$T/out")"
before=$(reqs)
cr send-logs --auto
[ "$(reqs)" = "$before" ] || fail "--auto повторил с тем же ключом"
printf 'test-token\n' > "$T/app/inbox-token"; touch -t "$(ago 1M)" "$STATUS"
cr send-logs --auto
[ "$(received | awk '{print $NF}')" = d_one ] && [ "$(head -1 "$STATUS")" = ok ] || fail "с новым ключом не дослал: $(received)"
echo "   ✓"

echo "▶︎ 413 — пачка делится пополам"
server "$T/srv" --logs-max-lines 2
for i in 1 2 3 4 5; do ev "e_$i"; done
before=$(reqs)
cr send-logs > /dev/null || fail "не дослал после 413"
[ "$(received | awk '{print $(NF-4), $(NF-3), $(NF-2), $(NF-1), $NF}')" = "e_1 e_2 e_3 e_4 e_5" ] && all_sent || fail "получено: $(received)"
tail -n +$((before + 1)) "$T/srv/requests.log" | grep -q "code=413" || fail "413 не было"
tail -n +$((before + 1)) "$T/srv/requests.log" | grep "code=200" | grep -qvE "lines=[12] " && fail "пачка больше 2 строк принята"
echo "   ✓"

echo "▶︎ журнал сменился (errors.jsonl → errors.jsonl.1) — дошлётся хвост прошлого и новый, без повторов"
server "$T/srv"
ev f_sent; cr send-logs > /dev/null
ev f_old1; ev f_old2
mv "$J" "$J.1"
ev f_new1; ev f_new2
before=$(reqs)
cr send-logs > "$T/out" || fail "send-logs: $(cat "$T/out")"
[ "$(received | awk '{print $(NF-3), $(NF-2), $(NF-1), $NF}')" = "f_old1 f_old2 f_new1 f_new2" ] && all_sent || fail "получено: $(received)"
tail -n +$((before + 1)) "$T/srv/requests.log" | grep -q "duplicates=[1-9]" && fail "события ушли повторно"
echo "   ✓"

echo "▶︎ позиция потеряна — всё уходит заново, сервер узнаёт повторы по id"
rm "$T/app/logs/send-logs.pos"
cr send-logs > "$T/out" || fail "send-logs: $(cat "$T/out")"
# Новым будет только logs_rejected про ту же испорченную строку.
grep -q "новых событий 1, уже были там" "$T/out" && all_sent || fail "вывод: $(cat "$T/out")"
echo "   ✓"

echo "▶︎ 600 событий — пачки по 500"
python3 -I - "$J" <<'PY'
import json, sys, uuid
with open(sys.argv[1], "a", encoding="utf-8") as f:
    for i in range(600):
        f.write(json.dumps({"id": str(uuid.uuid4()), "time": "2026-10-30T10:00:00+02:00", "level": "info", "source": "script",
                            "event": f"bulk_{i}", "message": "много"}, ensure_ascii=False) + "\n")
PY
before=$(reqs)
cr send-logs > /dev/null || fail "не дослал 600 событий"
[ "$(tail -n +$((before + 1)) "$T/srv/requests.log" | sed -n 's/.*lines=\([0-9]*\) .*/\1/p' | tr '\n' ' ')" = "500 100 " ] && all_sent \
    || fail "пачки: $(tail -n +$((before + 1)) "$T/srv/requests.log")"
echo "   ✓"

echo "▶︎ 200, но ответ не от нашего сервера — события не считаются отправленными"
server "$T/srv-garbage" --logs-garbage
ev g_one
cr send-logs > "$T/out" && fail "должно не удаться"
grep -q "непонятный ответ сервера" "$T/out" && ! all_sent || fail "вывод: $(cat "$T/out")"
server "$T/srv"
cr send-logs > /dev/null && [ "$(received | awk '{print $NF}')" = g_one ] || fail "не дослал: $(received)"
echo "   ✓"

echo "▶︎ после «off» журнал уходит сам, в фоне"
ev h_one
cr off > /dev/null
for _ in $(seq 1 40); do [ "$(received | awk '{print $NF}')" = h_one ] && all_sent && break; sleep 0.25; done
[ "$(received | awk '{print $NF}')" = h_one ] && all_sent || fail "после off журнал не ушёл: $(cat "$T/app/logs/send-logs.log")"
cr status | grep -q "Журнал ошибок на сервере: отправлен" || fail "status: $(cr status)"
echo "   ✓"

grep -rqs -e "test-token" -e "wrong-token" "$T/app/logs" && fail "ключ попал в файлы журнала"
echo "✅ Отправка журнала: все проверки пройдены"
