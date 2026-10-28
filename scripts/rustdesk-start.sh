#!/usr/bin/env bash
#
# Запуск RustDesk при работающем sing-box.
#
# RustDesk 1.4.8 падает на старте, если поднят TUN-интерфейс sing-box:
#   default-net-0.14.1/src/interface/unix.rs:178: index out of bounds
# Уже запущенному RustDesk туннель не мешает — падает только перечисление
# интерфейсов при старте.
#
# Порядок:
#   1. Пробуем запустить RustDesk как есть — вдруг обновление починило баг.
#   2. Не вышло — останавливаем демон, запускаем RustDesk, поднимаем демон.
# Демон поднимается обратно на любом выходе, в том числе по Ctrl-C.

set -uo pipefail

LABEL="com.singbox.daemon"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
APP="RustDesk"
TUN_ADDR="172.18.0.1"
SETTLE=8   # секунд: RustDesk падает в первые ~2 с, 8 — с запасом

STOPPED=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

app_running()    { pgrep -xq "$APP"; }
daemon_loaded()  { sudo launchctl print "system/${LABEL}" >/dev/null 2>&1; }
tun_up()         { ifconfig | grep -q "inet ${TUN_ADDR} "; }

# true, если RustDesk запустился и прожил SETTLE секунд
try_launch() {
    open -a "$APP" || return 1
    sleep "$SETTLE"
    app_running
}

cleanup() {
    local rc=$?
    if [ "$STOPPED" -eq 1 ]; then
        log "Поднимаю sing-box обратно"
        if ! daemon_loaded; then
            sudo launchctl bootstrap system "$PLIST" \
                || warn "bootstrap не удался — см. README, раздел «Служба не запускается после аварийного отката»"
        fi
        for _ in $(seq 1 20); do
            tun_up && break
            sleep 0.5
        done
        if tun_up; then ok "Туннель поднят"; else warn "Туннель не поднялся — проверьте: launchctl print system/${LABEL}"; fi
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if app_running; then
    ok "$APP уже запущен"
    open -a "$APP"
    exit 0
fi

if ! tun_up; then
    log "Туннель не поднят — запускаю $APP напрямую"
    try_launch && { ok "$APP запущен"; exit 0; }
    die "$APP падает даже без туннеля — дело не в sing-box. Логи: ~/Library/Logs/DiagnosticReports/${APP}-*.ips"
fi

log "Пробую запустить $APP при работающем туннеле"
if try_launch; then
    ok "$APP запущен, VPN не трогали — похоже, баг исправлен и скрипт больше не нужен"
    exit 0
fi
warn "$APP упал на старте — перезапускаю без туннеля"

sudo -v || die "Нужен sudo для остановки демона"

log "Останавливаю sing-box (туннель пропадёт на ~10 с)"
STOPPED=1
sudo launchctl bootout "system/${LABEL}" 2>/dev/null
for _ in $(seq 1 20); do
    tun_up || break
    sleep 0.5
done
tun_up && die "Туннель не исчез после остановки демона"

log "Запускаю $APP"
try_launch || die "$APP не запустился и без туннеля"
ok "$APP запущен"
# sing-box поднимет cleanup()
