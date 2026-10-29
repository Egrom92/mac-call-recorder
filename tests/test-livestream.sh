#!/bin/bash
# Проверка LiveStream на локальном сервере-имитаторе (без настоящего сервера и без настоящего ключа).
#   bash tests/test-livestream.sh
# 1) растущий WAV как у CallTap: 48 кГц стерео, канал 1 — тон 440 Гц («собеседник»), канал 2 — 1000 Гц («я»);
#    проверяем порядок и размер кусков, повтор после 503, частоты и длительность полученного звука 16 кГц;
# 2) сервер отвечает 409 — эфир должен остановиться.
# В обоих случаях проверяем журнал ошибок logs/errors.jsonl: правильный JSON, нужные события, ключа сервера нет.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/livestream-test.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$T"' EXIT
PORT=$((20000 + RANDOM % 20000))
fail() { echo "❌ $*"; exit 1; }
# Журнал ошибок: каждая строка — JSON с обязательными полями, ключа сервера нет; печатает события через пробел.
journal() { python3 -I - "$1" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
assert "test-token" not in text, "ключ сервера попал в журнал"
events = [json.loads(l) for l in text.splitlines()]
for e in events:
    missing = {"id", "time", "level", "source", "event", "message", "host", "version"} - e.keys()
    assert not missing, f"нет полей {missing}: {e}"
print(" ".join(e["event"] for e in events))
PY
}

echo "▶︎ сборка LiveStream"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$T/LiveStream" "$ROOT/src/LiveStream/main.swift" 2>/dev/null
mkdir -p "$T/app/logs"
printf 'test-token\n' > "$T/app/inbox-token"

ffmpeg -v error -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
       -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=6" \
       -filter_complex "[0:a][1:a]join=inputs=2:channel_layout=stereo" -c:a pcm_s16le "$T/source.wav"

# Пишет WAV в dest порциями по 0,1 с — как CallTap во время записи.
grow() { python3 -I - "$1" "$2" <<'PY'
import sys, time
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
step = 48000 * 4 // 10
with open(dst, "wb") as f:
    f.write(data[:44]); f.flush()
    for i in range(44, len(data), step):
        f.write(data[i:i + step]); f.flush(); time.sleep(0.1)
PY
}

run_case() {  # $1 — папка результата, $2… — доп. аргументы сервера
    local out="$1"; shift
    python3 -I "$ROOT/tests/live_mock_server.py" --port "$PORT" --out "$out" "$@" & local srv=$!
    sleep 0.5
    CALL_RECORDER_DIR="$T/app" "$T/LiveStream" "$out/rec.wav" "2026-10-28_18-30_Тест Тестов" "http://127.0.0.1:$PORT/" \
        > "$out/live.log" 2>&1 & local ls=$!
    grow "$T/source.wav" "$out/rec.wav"
    sleep 1
    kill -TERM $ls 2>/dev/null || true
    for _ in $(seq 1 100); do kill -0 $ls 2>/dev/null || break; sleep 0.1; done
    kill $srv 2>/dev/null || true
}

echo "▶︎ случай 1: обычный эфир"
mkdir -p "$T/case1"; run_case "$T/case1"
python3 -I - "$T/case1" <<'PY' || exit 1
import sys, struct, math
out = sys.argv[1]
lines = [l.split() for l in open(f"{out}/requests.log")]
for track, freq in (("me", 1000), ("them", 440)):
    ok = [l for l in lines if l[1] == track and l[4] == "200"]
    seqs = [int(l[2]) for l in ok]
    assert seqs == list(range(len(seqs))), f"{track}: номера не по порядку: {seqs}"
    sizes = [int(l[3]) for l in ok]
    assert all(s == 16000 for s in sizes[:-1]), f"{track}: размеры кусков {sizes}"
    pcm = open(f"{out}/{track}.pcm", "rb").read()
    n = len(pcm) // 2
    dur = n / 16000
    assert 5.8 <= dur <= 6.2, f"{track}: длительность {dur:.2f} с вместо 6"
    s = struct.unpack(f"<{n}h", pcm[: n * 2])
    mid = s[8000:-8000]
    crossings = sum(1 for a, b in zip(mid, mid[1:]) if a < 0 <= b)
    f = crossings / (len(mid) / 16000)
    assert abs(f - freq) < freq * 0.03, f"{track}: частота {f:.0f} Гц вместо {freq}"
    print(f"   {track}: {len(seqs)} кусков, {dur:.2f} с, тон {f:.0f} Гц ✓")
retry = [l for l in lines if l[1] == "me" and l[2] == "2"]
assert [l[4] for l in retry] == ["503", "200"], f"повтор после 503: {retry}"
print("   повтор после 503 ✓")
PY
grep -q "^stopped" "$T/app/logs/live-status" || fail "статус в конце не stopped"
echo "   статус в конце: $(cat "$T/app/logs/live-status") ✓"
events=$(journal "$T/app/logs/errors.jsonl") || fail "журнал ошибок испорчен"
[[ " $events " == *" live_http_error "* && " $events " == *" live_summary "* ]] || fail "в журнале нет сбоя 503 или итога: $events"
python3 -I - "$T/app/logs/errors.jsonl" <<'PY' || exit 1
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
err = next(e for e in ev if e["event"] == "live_http_error")
assert err["details"]["http"] == 503 and err["details"]["track"] == "me" and err["session"].endswith("Тест Тестов"), err
s = next(e for e in ev if e["event"] == "live_summary")
assert s["level"] == "warning" and s["details"]["sent_me"] == 12 and s["details"]["sent_them"] == 12, s
assert s["details"]["problems"] == {"503": 1} and s["details"]["lost"] == 0, s
PY
echo "   журнал ошибок: сбой 503 с дорожкой и номером куска, итог эфира 12/12 ✓"
mv "$T/app/logs/errors.jsonl" "$T/case1/errors.jsonl"

echo "▶︎ случай 2: сервер закрыл разговор (409)"
mkdir -p "$T/case2"; run_case "$T/case2" --close-after 3
grep -q "разговор уже закрыт (409)" "$T/case2/live.log" || fail "нет остановки по 409: $(cat "$T/case2/live.log")"
after=$(awk '$4 >= 0 && $5 == "409"' "$T/case2/requests.log" | wc -l | tr -d ' ')
[ "$after" -le 2 ] || fail "после 409 запросы продолжились ($after)"
echo "   эфир остановлен после 409 ✓"
events=$(journal "$T/app/logs/errors.jsonl") || fail "журнал ошибок испорчен"
[[ " $events " == *" live_closed "* ]] || fail "в журнале нет остановки по 409: $events"
echo "   журнал ошибок: остановка по 409 ✓"

echo "✅ LiveStream: все проверки пройдены"
