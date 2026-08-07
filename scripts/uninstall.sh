#!/usr/bin/env bash
#
# Полное удаление sing-box-демона и возврат системы в исходное состояние.
#
# Идемпотентен: повторный запуск на уже очищенной системе отработает без ошибок.
# Hiddify не трогает.
#
# По умолчанию удаляет и бинарник. Чтобы оставить его:
#     sudo ./scripts/uninstall.sh --keep-binary

set -uo pipefail

TUN_ADDR="${TUN_ADDR:-172.18.0.1}"
BIN_PATH="/usr/local/bin/sing-box"
ETC_DIR="/etc/sing-box"
LIB_DIR="/var/lib/sing-box"
LOG_DIR="/var/log/sing-box"
LIBEXEC_DIR="/usr/local/libexec/sing-box"
DAEMON_PLIST="/Library/LaunchDaemons/com.singbox.daemon.plist"
UPDATE_PLIST="/Library/LaunchDaemons/com.singbox.ruleset-update.plist"
NEWSYSLOG_CONF="/etc/newsyslog.d/sing-box.conf"

AUTO_ROUTE_RANGES=(
    "1.0.0.0/8" "2.0.0.0/7" "4.0.0.0/6" "8.0.0.0/5"
    "16.0.0.0/4" "32.0.0.0/3" "64.0.0.0/2" "128.0.0.0/1"
)

KEEP_BINARY=0
[ "${1:-}" = "--keep-binary" ] && KEEP_BINARY=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { printf 'Нужны права root. Запустите: sudo %s\n' "$0" >&2; exit 1; }

log "Удаление sing-box-демона"

# --- 1. Остановка служб -----------------------------------------------------
log "Останавливаю службы"
for label in com.singbox.daemon com.singbox.ruleset-update; do
    if launchctl print "system/${label}" >/dev/null 2>&1; then
        launchctl bootout "system/${label}" 2>/dev/null && ok "выгружен ${label}" \
            || warn "не удалось выгрузить ${label}"
    else
        ok "${label} не был загружен"
    fi
    # Снимаем возможный disable от emergency-reset, чтобы не осталось следов
    launchctl enable "system/${label}" 2>/dev/null || true
done

# --- 2. Процессы ------------------------------------------------------------
if pgrep -x sing-box >/dev/null 2>&1; then
    log "Останавливаю процессы sing-box"
    pkill -TERM -x sing-box 2>/dev/null
    for _ in $(seq 1 10); do
        pgrep -x sing-box >/dev/null 2>&1 || break
        sleep 0.5
    done
    pgrep -x sing-box >/dev/null 2>&1 && { pkill -KILL -x sing-box 2>/dev/null; sleep 1; }
    ok "процессы остановлены"
fi

# --- 3. Маршруты ------------------------------------------------------------
log "Убираю маршруты туннеля"
removed=0
for net in "${AUTO_ROUTE_RANGES[@]}"; do
    route -n delete -net "$net" >/dev/null 2>&1 && removed=$((removed+1))
done
while read -r dest; do
    [ -n "$dest" ] || continue
    route -n delete "$dest" >/dev/null 2>&1 && removed=$((removed+1))
done < <(netstat -rn -f inet 2>/dev/null | awk -v gw="$TUN_ADDR" '$2==gw {print $1}')
ok "удалено маршрутов: ${removed}"

# --- 4. Файлы служб ---------------------------------------------------------
log "Удаляю файлы"
for f in "$DAEMON_PLIST" "$UPDATE_PLIST" "$NEWSYSLOG_CONF"; do
    if [ -e "$f" ]; then
        rm -f "$f" && ok "удалён $f"
    else
        ok "$f отсутствует"
    fi
done

for d in "$ETC_DIR" "$LIB_DIR" "$LIBEXEC_DIR"; do
    if [ -d "$d" ]; then
        rm -rf "$d" && ok "удалён каталог $d"
    else
        ok "каталог $d отсутствует"
    fi
done

# Логи удаляем последними и отдельно — иногда их хочется сохранить
if [ -d "$LOG_DIR" ]; then
    rm -rf "$LOG_DIR" && ok "удалён каталог $LOG_DIR"
fi

# --- 5. Бинарник ------------------------------------------------------------
if [ "$KEEP_BINARY" -eq 1 ]; then
    ok "бинарник оставлен по флагу --keep-binary: $BIN_PATH"
elif [ -f "$BIN_PATH" ]; then
    rm -f "$BIN_PATH" && ok "удалён $BIN_PATH"
else
    ok "$BIN_PATH отсутствует"
fi

# --- 6. DNS -----------------------------------------------------------------
log "Сбрасываю DNS-кеш"
dscacheutil -flushcache 2>/dev/null && ok "кеш сброшен"
killall -HUP mDNSResponder 2>/dev/null && ok "mDNSResponder перезапущен" || true

# --- 7. Проверка ------------------------------------------------------------
log "Проверяю состояние сети"
def_gw="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
def_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
printf '    маршрут по умолчанию: %s через %s\n' "${def_gw:-нет}" "${def_if:-нет}"
printf '    маршрутов в таблице: %s\n' "$(netstat -rn 2>/dev/null | wc -l | tr -d ' ')"

if ifconfig 2>/dev/null | grep -q "inet ${TUN_ADDR}"; then
    warn "интерфейс с адресом ${TUN_ADDR} всё ещё существует"
else
    ok "интерфейсов туннеля не осталось"
fi

if curl -sS -m 12 -o /dev/null https://api.ipify.org 2>/dev/null; then
    ok "интернет работает: $(curl -sS -m 12 https://api.ipify.org 2>/dev/null)"
else
    warn "интернет не отвечает — проверьте Wi-Fi или запустите Hiddify"
fi

cat <<EOF

$(printf '\033[1;32m')Удаление завершено.$(printf '\033[0m')

Что НЕ тронуто:
  * Hiddify и его настройки
  * файлы проекта в этом каталоге (включая config/secrets/)

Проверить, что ничего не осталось:
  ls -la /Library/LaunchDaemons/ | grep -i singbox
  launchctl print system/com.singbox.daemon 2>&1 | head -1
EOF
