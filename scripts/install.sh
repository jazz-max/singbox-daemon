#!/usr/bin/env bash
#
# Установка sing-box как системного LaunchDaemon на macOS (Apple Silicon).
#
# Скрипт ИДЕМПОТЕНТЕН: повторный запуск приводит систему к тому же состоянию
# и не ломает уже работающую установку.
#
# Скрипт НЕ ЗАПУСКАЕТ демон. Это сделано намеренно: перед автозапуском нужно
# убедиться в foreground-режиме, что туннель работает и вы не останетесь без
# сети. Порядок:
#
#     sudo ./scripts/install.sh          # разложить файлы, проверить конфиг
#     sudo ./scripts/preflight.sh        # запуск в foreground, проверки
#     sudo ./scripts/install.sh --enable-daemon   # только теперь автозапуск
#
# Требует root (sudo). Hiddify не трогает — он остаётся рабочим запасным вариантом.

set -euo pipefail

# --- Параметры --------------------------------------------------------------
SB_VERSION="${SB_VERSION:-1.13.16}"
SB_ARCH="darwin-arm64"
SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-${SB_ARCH}.tar.gz"
# sha256 архива sing-box-1.13.16-darwin-arm64.tar.gz, проверен вручную 2026-08-07
SB_SHA256="${SB_SHA256:-32fa21fd75ad62d86a2dcb7e0be77359c35e12798cdbb6a0e30654ef487d90d6}"

BIN_PATH="/usr/local/bin/sing-box"
ETC_DIR="/etc/sing-box"
LIB_DIR="/var/lib/sing-box"
RULESET_DIR="${LIB_DIR}/rulesets"
LOG_DIR="/var/log/sing-box"
LIBEXEC_DIR="/usr/local/libexec/sing-box"
DAEMON_PLIST="/Library/LaunchDaemons/com.singbox.daemon.plist"
UPDATE_PLIST="/Library/LaunchDaemons/com.singbox.ruleset-update.plist"
NEWSYSLOG_CONF="/etc/newsyslog.d/sing-box.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-${PROJECT_DIR}/config/secrets/outbounds.json}"

ENABLE_DAEMON=0
[ "${1:-}" = "--enable-daemon" ] && ENABLE_DAEMON=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Проверки окружения -----------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "нужны права root. Запустите: sudo $0 ${1:-}"
[ "$(uname -s)" = "Darwin" ] || die "скрипт рассчитан на macOS"
[ "$(uname -m)" = "arm64" ] || warn "архитектура $(uname -m), а бинарник качается для arm64"

# --- Режим включения автозапуска (всё остальное уже установлено) ------------
if [ "$ENABLE_DAEMON" -eq 1 ]; then
    log "Включаю автозапуск демона"
    [ -f "$DAEMON_PLIST" ] || die "не найден $DAEMON_PLIST — сначала запустите install.sh без флагов"
    [ -f "${ETC_DIR}/config.json" ] || die "не найден конфиг ${ETC_DIR}/config.json"

    "$BIN_PATH" check -c "${ETC_DIR}/config.json" || die "конфиг не проходит проверку, автозапуск не включён"
    ok "конфиг валиден"

    # bootout перед bootstrap делает операцию идемпотентной
    launchctl bootout system/com.singbox.daemon 2>/dev/null || true
    launchctl bootstrap system "$DAEMON_PLIST"
    ok "демон com.singbox.daemon загружен"

    launchctl bootout system/com.singbox.ruleset-update 2>/dev/null || true
    launchctl bootstrap system "$UPDATE_PLIST"
    ok "задание обновления списка загружено"

    sleep 3
    if launchctl print system/com.singbox.daemon >/dev/null 2>&1; then
        pid="$(launchctl print system/com.singbox.daemon 2>/dev/null | awk '/^\tpid = /{print $3}')"
        ok "демон работает, pid=${pid:-неизвестен}"
    else
        die "демон не поднялся, смотрите ${LOG_DIR}/sing-box.err.log"
    fi

    log "Готово. Проверьте: ./scripts/healthcheck.sh"
    exit 0
fi

# --- 1. Каталоги ------------------------------------------------------------
log "Создаю каталоги"
install -d -o root -g wheel -m 0755 "$ETC_DIR"
install -d -o root -g wheel -m 0755 "$LIB_DIR"
install -d -o root -g wheel -m 0755 "$RULESET_DIR"
install -d -o root -g wheel -m 0755 "$LOG_DIR"
install -d -o root -g wheel -m 0755 "$LIBEXEC_DIR"
install -d -o root -g wheel -m 0755 /usr/local/bin
ok "каталоги на месте"

# --- 2. Бинарник ------------------------------------------------------------
need_download=1
if [ -x "$BIN_PATH" ]; then
    current="$("$BIN_PATH" version 2>/dev/null | awk '/^sing-box version/{print $3}')" || current=""
    if [ "$current" = "$SB_VERSION" ]; then
        ok "sing-box ${SB_VERSION} уже установлен"
        need_download=0
    else
        warn "установлена версия '${current:-неизвестна}', будет заменена на ${SB_VERSION}"
    fi
fi

if [ "$need_download" -eq 1 ]; then
    log "Скачиваю sing-box ${SB_VERSION}"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -sS -L --fail --max-time 300 -o "${tmp}/sb.tar.gz" "$SB_URL" \
        || die "не удалось скачать $SB_URL"

    actual="$(shasum -a 256 "${tmp}/sb.tar.gz" | awk '{print $1}')"
    [ "$actual" = "$SB_SHA256" ] \
        || die "sha256 не совпал!
       ожидалось: $SB_SHA256
       получено:  $actual
       Установка прервана — возможна подмена файла."
    ok "sha256 совпал"

    tar -xzf "${tmp}/sb.tar.gz" -C "$tmp"
    install -o root -g wheel -m 0755 \
        "${tmp}/sing-box-${SB_VERSION}-${SB_ARCH}/sing-box" "$BIN_PATH"
    ok "установлен $BIN_PATH ($("$BIN_PATH" version | head -1))"
    rm -rf "$tmp"
    trap - EXIT
fi

# --- 3. Вспомогательные скрипты --------------------------------------------
log "Устанавливаю служебные скрипты"
install -o root -g wheel -m 0755 "${SCRIPT_DIR}/build-ruleset.sh" "${LIBEXEC_DIR}/build-ruleset.sh"
install -o root -g wheel -m 0755 "${SCRIPT_DIR}/aggregate.py"     "${LIBEXEC_DIR}/aggregate.py"
ok "${LIBEXEC_DIR}"

# --- 4. Доменный оверрайд ---------------------------------------------------
log "Устанавливаю доменный список-оверрайд"
install -o root -g wheel -m 0644 \
    "${PROJECT_DIR}/rulesets/ru-direct-domains.json" \
    "${RULESET_DIR}/ru-direct-domains.json"
ok "${RULESET_DIR}/ru-direct-domains.json"

# --- 5. Список российских подсетей -----------------------------------------
if [ -f "${RULESET_DIR}/ru-ip.srs" ]; then
    ok "ru-ip.srs уже есть ($(wc -c < "${RULESET_DIR}/ru-ip.srs" | tr -d ' ') байт), пересборка не требуется"
    warn "обновить вручную: sudo ${LIBEXEC_DIR}/build-ruleset.sh"
else
    log "Собираю список российских подсетей (первый запуск)"
    DEST_DIR="$RULESET_DIR" SING_BOX="$BIN_PATH" "${LIBEXEC_DIR}/build-ruleset.sh" \
        || die "не удалось собрать rule-set"
fi

# --- 6. Конфиг --------------------------------------------------------------
log "Собираю конфигурацию"
[ -f "$SECRETS_FILE" ] || die "не найден файл с подпиской: $SECRETS_FILE
       Выгрузите outbounds из Hiddify в формате sing-box и положите его туда.
       Образец структуры: ${PROJECT_DIR}/config/outbounds.example.json"

python3 "${SCRIPT_DIR}/render-config.py" \
    --template "${PROJECT_DIR}/config/config.template.json" \
    --secrets  "$SECRETS_FILE" \
    --out      "${PROJECT_DIR}/config/config.generated.json" \
    || die "не удалось собрать конфиг"

install -o root -g wheel -m 0600 \
    "${PROJECT_DIR}/config/config.generated.json" "${ETC_DIR}/config.json"
ok "${ETC_DIR}/config.json (600 root:wheel)"

log "Проверяю конфигурацию"
"$BIN_PATH" check -c "${ETC_DIR}/config.json" || die "конфиг не проходит sing-box check"
ok "sing-box check пройдена"

# --- 7. LaunchDaemon plist'ы (файлы кладём, но не загружаем) ---------------
log "Устанавливаю LaunchDaemon-задания"
install -o root -g wheel -m 0644 "${PROJECT_DIR}/launchd/com.singbox.daemon.plist" "$DAEMON_PLIST"
install -o root -g wheel -m 0644 "${PROJECT_DIR}/launchd/com.singbox.ruleset-update.plist" "$UPDATE_PLIST"
ok "$DAEMON_PLIST"
ok "$UPDATE_PLIST"
plutil -lint "$DAEMON_PLIST" >/dev/null && plutil -lint "$UPDATE_PLIST" >/dev/null
ok "plist-файлы синтаксически корректны"

# --- 8. Ротация логов -------------------------------------------------------
install -d -o root -g wheel -m 0755 /etc/newsyslog.d
install -o root -g wheel -m 0644 "${PROJECT_DIR}/launchd/sing-box.newsyslog.conf" "$NEWSYSLOG_CONF"
ok "$NEWSYSLOG_CONF"

# --- Итог -------------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32m')Файлы установлены. Демон НЕ запущен — это следующий шаг.$(printf '\033[0m')

Дальше, по порядку:

  1. Проверка в foreground (можно прервать по Ctrl-C в любой момент):

         sudo ./scripts/preflight.sh

     Скрипт поднимет sing-box на переднем плане и прогонит проверки:
     внешний IP через прокси, российский IP напрямую, DNS, локальная сеть.

  2. Если всё хорошо — включить автозапуск:

         sudo ./scripts/install.sh --enable-daemon

  3. Если что-то пойдёт не так — аварийный откат:

         sudo ./scripts/emergency-reset.sh

Hiddify не тронут и остаётся рабочим запасным вариантом.
EOF
