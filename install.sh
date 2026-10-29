#!/bin/bash
# Установка «Запись звонков» (mac-call-recorder).
#   curl -fsSL https://raw.githubusercontent.com/Egrom92/mac-call-recorder/main/install.sh | bash
# или из клона репозитория:  ./install.sh
# Повторный запуск обновляет программу до последней версии; записи не трогаются.
set -euo pipefail

REPO="Egrom92/mac-call-recorder"
DIR="$HOME/.call-recorder"
CALLTAP_APP="$DIR/CallTap.app"
MENU_APP="$HOME/Applications/Запись звонков.app"

say() { printf '\n\033[1m▶︎ %s\033[0m\n' "$*"; }
die() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

# --- 1. Система ---------------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "Нужен macOS."
ver=$(sw_vers -productVersion)
major=${ver%%.*}; minor=$(echo "$ver" | cut -d. -f2)
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "${minor:-0}" -lt 4 ]; }; then
    die "Нужна macOS 14.4 или новее (у вас $ver)."
fi
arch=$(uname -m)   # arm64 или x86_64

if pgrep -f "$CALLTAP_APP/Contents/MacOS/CallTap record" >/dev/null; then
    die "Сейчас идёт запись. Остановите её (call-recorder off или кнопкой) и запустите установку снова."
fi

# --- 2. Исходники: из клона или архивом с GitHub -------------------------------
SRC=""
self="${BASH_SOURCE[0]:-}"
if [ -n "$self" ] && [ -f "$(dirname "$self")/src/CallTap/main.swift" ]; then
    SRC="$(cd "$(dirname "$self")" && pwd)"
else
    say "Скачиваю исходники с GitHub"
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/mac-call-recorder.XXXXXX")
    trap 'rm -rf "$TMP"' EXIT
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$TMP"
    SRC="$TMP/mac-call-recorder-main"
fi

# --- 3. Инструменты разработчика Apple (компилятор Swift) ---------------------
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    say "Нужны бесплатные инструменты разработчика Apple (Command Line Tools)"
    echo "Сейчас откроется окно установки — нажмите «Установить», дождитесь окончания и запустите эту установку ещё раз."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

# --- 4. Homebrew, BlackHole, ffmpeg -------------------------------------------
if ! command -v brew >/dev/null; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$b" ]; then eval "$("$b" shellenv)"; break; fi
    done
fi
command -v brew >/dev/null || die "Нужен Homebrew. Установите его одной командой с https://brew.sh и запустите эту установку ещё раз."

if ! brew list --cask blackhole-2ch >/dev/null 2>&1; then
    say "Ставлю BlackHole 2ch (виртуальное аудиоустройство; macOS спросит пароль администратора)"
    brew install --cask blackhole-2ch
fi
if ! brew list ffmpeg >/dev/null 2>&1; then
    say "Ставлю ffmpeg (сохранение записей в m4a)"
    brew install ffmpeg
fi

# --- 5. Сборка ----------------------------------------------------------------
build() {   # $1 — исходник, $2 — путь к .app, $3 — имя исполняемого файла, $4 — минимальная macOS
    mkdir -p "$2/Contents/MacOS"
    local log; log=$(mktemp)
    if ! swiftc -O -swift-version 5 -target "$arch-apple-macos$4" -o "$2/Contents/MacOS/$3" "$1" 2>"$log"; then
        cat "$log" >&2; die "Не удалось собрать $3"
    fi
    rm -f "$log"
}

plist() {   # $1 — путь к .app, остальное — строки <key>…</key><value> внутри <dict>
    local app="$1"; shift
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0"><dict>'
        printf '    %s\n' "$@"
        echo '</dict></plist>'
    } > "$app/Contents/Info.plist"
    codesign --force --sign - "$app" 2>/dev/null
}

mkdir -p "$DIR/logs" "$DIR/current"
# Каждая пересборка меняет подпись CallTap, и macOS заново спрашивает разрешения, поэтому
# пересобираем его, только если изменился исходник.
calltap_hash=$(shasum -a 256 "$SRC/src/CallTap/main.swift" | cut -d' ' -f1)
CALLTAP_BUILT=0
if [ -x "$CALLTAP_APP/Contents/MacOS/CallTap" ] && [ "$(cat "$DIR/.calltap-source.sha256" 2>/dev/null)" = "$calltap_hash" ]; then
    say "CallTap не изменился — оставляю как есть (разрешения macOS сохранятся)"
else
say "Собираю CallTap (захват звука)"
CALLTAP_BUILT=1
build "$SRC/src/CallTap/main.swift" "$CALLTAP_APP" CallTap 14.4
plist "$CALLTAP_APP" \
    '<key>CFBundleIdentifier</key><string>local.call-recorder.calltap</string>' \
    '<key>CFBundleName</key><string>CallTap</string>' \
    '<key>CFBundleDisplayName</key><string>CallTap (запись звонков)</string>' \
    '<key>CFBundleExecutable</key><string>CallTap</string>' \
    '<key>CFBundlePackageType</key><string>APPL</string>' \
    '<key>CFBundleShortVersionString</key><string>1.0</string>' \
    '<key>LSMinimumSystemVersion</key><string>14.4</string>' \
    '<key>LSUIElement</key><true/>' \
    '<key>NSAudioCaptureUsageDescription</key><string>CallTap записывает голос собеседника во время звонка.</string>' \
    '<key>NSMicrophoneUsageDescription</key><string>CallTap записывает ваш голос с микрофона во время звонка.</string>'
echo "$calltap_hash" > "$DIR/.calltap-source.sha256"
fi

say "Собираю LiveStream (прямой эфир на сервер)"
# Обычный исполняемый файл без разрешений macOS: читает файл записи и отправляет звук, поэтому пересборка ничего не сбрасывает.
live_log=$(mktemp)
if ! swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" -o "$DIR/LiveStream" "$SRC/src/LiveStream/main.swift" 2>"$live_log"; then
    cat "$live_log" >&2; die "Не удалось собрать LiveStream"
fi
rm -f "$live_log"

say "Собираю кнопку «Запись звонков» для строки меню"
pkill -f "Запись звонков.app/Contents/MacOS/CallRecorderMenu" 2>/dev/null || true
build "$SRC/src/MenuBar/main.swift" "$MENU_APP" CallRecorderMenu 14.0
plist "$MENU_APP" \
    '<key>CFBundleIdentifier</key><string>local.call-recorder.menu</string>' \
    '<key>CFBundleName</key><string>Запись звонков</string>' \
    '<key>CFBundleExecutable</key><string>CallRecorderMenu</string>' \
    '<key>CFBundlePackageType</key><string>APPL</string>' \
    '<key>CFBundleShortVersionString</key><string>1.0</string>' \
    '<key>LSMinimumSystemVersion</key><string>14.0</string>' \
    '<key>LSUIElement</key><true/>'

say "Ставлю команду call-recorder"
install -m 755 "$SRC/call-recorder.sh" "$DIR/call-recorder.sh"
# Версия — в каждом событии журнала ошибок: коммит, если ставим из клона, иначе дата установки.
git -C "$SRC" describe --always --dirty 2>/dev/null > "$DIR/version" || echo "main-$(date +%F)" > "$DIR/version"
ln -sf "$DIR/call-recorder.sh" "$(brew --prefix)/bin/call-recorder"

# --- 6. Проверка BlackHole и разрешений ----------------------------------------
if ! system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole 2ch"; then
    say "BlackHole 2ch пока не виден системе — перезагрузите Mac, и всё заработает."
elif [ "$CALLTAP_BUILT" = 1 ]; then
    # Первый запуск свежесобранного CallTap показывает окна разрешений; пока они открыты, запись не стартует.
    # Первые секунды микрофон AirPods молчит (переключается в режим гарнитуры), поэтому судим по второй
    # строке уровней — она появляется через 13 секунд.
    say "Проверяю запись (около 15 секунд). macOS спросит доступ CallTap к микрофону и к записи системного звука — нажмите «Разрешить»."
    test_log="$DIR/logs/install-check.log"; : > "$test_log"
    open -n -g "$CALLTAP_APP" --stdout "$test_log" --stderr "$test_log" --args record "$DIR/logs/install-check.wav"
    for _ in $(seq 1 90); do
        [ "$(grep -c "уровень" "$test_log")" -ge 2 ] && break
        grep -q "❌" "$test_log" && break
        sleep 0.5
    done
    pkill -TERM -f "$CALLTAP_APP/Contents/MacOS/CallTap record" 2>/dev/null || true
    sleep 1
    rm -f "$DIR/logs/install-check.wav"
    if [ "$(grep -c "уровень" "$test_log")" -ge 2 ]; then
        grep "уровень" "$test_log" | tail -1 | sed 's/^/   /'
        if grep "уровень" "$test_log" | tail -1 | grep -q "микрофон   -inf"; then
            echo "   Микрофон пишет тишину: разрешите CallTap в Системных настройках →"
            echo "   Конфиденциальность и безопасность → Микрофон (если уже разрешён — выключите и включите снова)."
        else
            echo "   ✓ запись работает"
        fi
    else
        echo "⚠️  Проверка не дождалась записи. Если окна разрешений ещё открыты — нажмите «Разрешить»,"
        echo "   потом запишите пробу кнопкой. Журнал проверки:"
        sed 's/^/   /' "$test_log"
    fi
fi

open "$MENU_APP"

cat <<'DONE'

✅ Готово!

  • В строке меню справа (рядом с батареей) появился кружок ◯ — это кнопка записи.
    Клик по нему открывает меню: «Начать запись» / «Завершить запись», шкалы громкости,
    «Показать детали…», папка с записями, автозапуск при входе в систему.
  • Из Терминала: call-recorder on ["Имя клиента"] | off | status
  • Записи: ~/Movies/Записи звонков
  • Отправка на свой сервер и «Прямой эфир» — меню «Сервер и ключ…» (по умолчанию выключено, см. README)
DONE
