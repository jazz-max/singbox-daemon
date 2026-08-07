#!/usr/bin/env bash
#
# АВАРИЙНЫЙ ОТКАТ. Возвращает сеть, если sing-box сломал маршрутизацию или DNS.
#
# Работает без интернета и ничего не скачивает — рассчитан на ситуацию,
# когда сети уже нет и вы сидите за локальной консолью.
#
# Что делает:
#   1. выгружает LaunchDaemon, чтобы он не поднялся снова;
#   2. останавливает процессы sing-box (сначала мягко — тогда он снимет маршруты сам);
#   3. вычищает маршруты, оставшиеся после аварийной остановки;
#   4. сбрасывает DNS-кеш;
#   5. проверяет, что связность вернулась.
#
# ПОЧЕМУ ЭТО НУЖНО. На macOS sing-box ставит маршруты сообщениями RTM_ADD
# в PF_ROUTE-сокет и снимает их в обработчике штатной остановки. Если процесс
# убит по SIGKILL или упал, снятие не выполняется, и покрывающие маршруты
# остаются в ядре — весь трафик уходит в несуществующий интерфейс.
#
# Запуск:  sudo ./scripts/emergency-reset.sh

set -uo pipefail

TUN_ADDR="${TUN_ADDR:-172.18.0.1}"

# Именно эти 8 подсетей ставит auto_route на darwin: они покрывают всё
# адресное пространство и выигрывают у системного default по длине префикса.
AUTO_ROUTE_RANGES=(
    "1.0.0.0/8" "2.0.0.0/7" "4.0.0.0/6" "8.0.0.0/5"
    "16.0.0.0/4" "32.0.0.0/3" "64.0.0.0/2" "128.0.0.0/1"
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { printf 'Нужны права root. Запустите: sudo %s\n' "$0" >&2; exit 1; }

printf '\033[1;31m'
cat <<'EOF'
=========================================
  АВАРИЙНЫЙ ОТКАТ sing-box
=========================================
EOF
printf '\033[0m\n'

# --- 1. Выгрузка LaunchDaemon ----------------------------------------------
log "Выгружаю LaunchDaemon"
for label in com.singbox.daemon com.singbox.ruleset-update; do
    if launchctl print "system/${label}" >/dev/null 2>&1; then
        launchctl bootout "system/${label}" 2>/dev/null && ok "выгружен ${label}" \
            || warn "не удалось выгрузить ${label}"
    else
        ok "${label} не был загружен"
    fi
done

# Чтобы не поднялся при следующей загрузке до выяснения причин
log "Отключаю автозапуск до разбирательства"
launchctl disable system/com.singbox.daemon 2>/dev/null && ok "автозапуск отключён" \
    || warn "launchctl disable не сработал (не критично)"

# --- 2. Остановка процессов -------------------------------------------------
log "Останавливаю процессы sing-box"
if pgrep -x sing-box >/dev/null 2>&1; then
    # Сначала мягко: при SIGTERM sing-box снимает свои маршруты сам
    pkill -TERM -x sing-box 2>/dev/null
    for _ in $(seq 1 10); do
        pgrep -x sing-box >/dev/null 2>&1 || break
        sleep 0.5
    done
    if pgrep -x sing-box >/dev/null 2>&1; then
        warn "не завершился штатно, применяю SIGKILL"
        pkill -KILL -x sing-box 2>/dev/null
        sleep 1
    else
        ok "процессы завершены штатно (маршруты сняты самим sing-box)"
    fi
else
    ok "работающих процессов sing-box нет"
fi

# --- 3. Чистка маршрутов ----------------------------------------------------
log "Убираю оставшиеся маршруты"
removed=0
for net in "${AUTO_ROUTE_RANGES[@]}"; do
    if route -n delete -net "$net" >/dev/null 2>&1; then
        ok "удалён маршрут $net"
        removed=$((removed+1))
    fi
done

# Всё, что ещё указывает на адрес туннеля
while read -r dest; do
    [ -n "$dest" ] || continue
    if route -n delete "$dest" >/dev/null 2>&1; then
        ok "удалён маршрут $dest (вёл через ${TUN_ADDR})"
        removed=$((removed+1))
    fi
done < <(netstat -rn -f inet 2>/dev/null | awk -v gw="$TUN_ADDR" '$2==gw {print $1}')

# Маршруты, ведущие в исчезнувшие utun-интерфейсы
while read -r dest ifname; do
    [ -n "$dest" ] || continue
    ifconfig "$ifname" >/dev/null 2>&1 && continue
    route -n delete "$dest" >/dev/null 2>&1 && {
        ok "удалён маршрут $dest в несуществующий $ifname"
        removed=$((removed+1))
    }
done < <(netstat -rn -f inet 2>/dev/null | awk '$NF ~ /^utun/ {print $1, $NF}')

[ "$removed" -eq 0 ] && ok "лишних маршрутов не найдено — таблица чистая"

# --- 4. DNS -----------------------------------------------------------------
log "Сбрасываю DNS"
dscacheutil -flushcache 2>/dev/null && ok "кеш DNS сброшен"
killall -HUP mDNSResponder 2>/dev/null && ok "mDNSResponder перезапущен" \
    || warn "mDNSResponder перезапустить не удалось"

# Если DNS когда-то задавался вручную через networksetup — вернуть на DHCP.
# Наш конфиг системный DNS не меняет, так что обычно менять нечего.
svc="$(networksetup -listnetworkserviceorder 2>/dev/null | awk -F'Device: ' '/Device: en0/{print $2}' | tr -d ')' | head -1)"
if [ -n "${svc:-}" ]; then
    :
fi
for service in "Wi-Fi" "Ethernet"; do
    cur="$(networksetup -getdnsservers "$service" 2>/dev/null)"
    case "$cur" in
        *"There aren't any DNS Servers set"*) ok "${service}: DNS от DHCP, менять нечего" ;;
        *"not a recognized network service"*) : ;;
        "") : ;;
        *) warn "${service}: заданы DNS вручную: $(echo "$cur" | tr '\n' ' ')"
           printf '        вернуть на DHCP: sudo networksetup -setdnsservers "%s" Empty\n' "$service" ;;
    esac
done

# --- 5. Состояние -----------------------------------------------------------
log "Текущее состояние"
printf '    маршрутов в таблице: %s\n' "$(netstat -rn 2>/dev/null | wc -l | tr -d ' ')"
def_gw="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
def_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
printf '    маршрут по умолчанию: %s через %s\n' "${def_gw:-нет}" "${def_if:-нет}"

if [ -n "${def_if:-}" ] && [ "${def_if#utun}" != "$def_if" ]; then
    warn "маршрут по умолчанию всё ещё указывает в туннель!"
    warn "проверьте, не работает ли Hiddify или другой VPN"
fi

log "Проверяю связность"
if ping -c 2 -t 3 "${def_gw:-192.168.1.1}" >/dev/null 2>&1; then
    ok "локальный шлюз отвечает"
else
    warn "локальный шлюз не отвечает — проблема ниже уровня маршрутизации (Wi-Fi?)"
fi

if curl -sS -m 12 -o /dev/null https://api.ipify.org 2>/dev/null; then
    ip="$(curl -sS -m 12 https://api.ipify.org 2>/dev/null)"
    ok "интернет работает, внешний адрес: ${ip}"
else
    warn "интернет не отвечает"
    printf '\n    Что попробовать дальше:\n'
    printf '      1. Выключить и включить Wi-Fi:\n'
    printf '         sudo ifconfig en0 down && sudo ifconfig en0 up\n'
    printf '      2. Посмотреть таблицу маршрутов:  netstat -rn -f inet | head -20\n'
    printf '      3. Запустить Hiddify — он остался нетронутым и должен работать\n'
fi

cat <<EOF

$(printf '\033[1;32m')Откат выполнен.$(printf '\033[0m')

Автозапуск демона ОТКЛЮЧЁН. Когда разберётесь с причиной, включить обратно:

    sudo launchctl enable system/com.singbox.daemon
    sudo ./scripts/install.sh --enable-daemon

Журнал демона: /var/log/sing-box/sing-box.err.log
EOF
