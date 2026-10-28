#!/usr/bin/env bash
#
# Проверка работоспособности split-tunneling.
#
# Запускается и после установки, и из preflight.sh во время foreground-прогона.
# Root не требуется (кроме чтения логов демона).
#
# Смысл главной проверки: два эхо-сервиса должны показать РАЗНЫЕ адреса.
#   api.ipify.org (зарубежный) -> идёт через туннель  -> покажет IP прокси
#   ip.beget.ru   (российский) -> идёт напрямую       -> покажет ваш IP от провайдера
#   (yandex.ru/internet/api/v0/ip с 2026-10 всегда отвечает "127.0.0.1" — не годится)
# Если оба показали одно и то же — split-tunneling не работает.

set -uo pipefail

TUN_ADDR="${TUN_ADDR:-172.18.0.1}"
RULESET_DIR="${RULESET_DIR:-/var/lib/sing-box/rulesets}"
SING_BOX="${SING_BOX:-/usr/local/bin/sing-box}"
TIMEOUT="${TIMEOUT:-15}"

pass=0; fail=0; skip=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  \033[33m·\033[0m %s\n' "$*"; skip=$((skip+1)); }
head_() { printf '\n\033[1;34m%s\033[0m\n' "$*"; }

# --- 1. Интерфейс -----------------------------------------------------------
head_ "TUN-интерфейс"
# Ищем интерфейс перебором, а не через grep -B: в блоке контекста первым
# может оказаться соседний utun (их на macOS обычно несколько), и тогда
# в отчёт попадут имя и MTU чужого интерфейса.
tun_if=""
for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^utun'); do
    if ifconfig "$iface" 2>/dev/null | grep -q "inet ${TUN_ADDR} "; then
        tun_if="$iface"
        break
    fi
done
if [ -n "$tun_if" ]; then
    mtu="$(ifconfig "$tun_if" | awk '/mtu/{print $NF; exit}')"
    ok "интерфейс $tun_if поднят с адресом ${TUN_ADDR}, MTU=${mtu}"
else
    bad "не найден интерфейс с адресом ${TUN_ADDR} — туннель не поднят"
fi

route_count="$(netstat -rn 2>/dev/null | wc -l | tr -d ' ')"
ok "записей в таблице маршрутизации: ${route_count}"
if [ "$route_count" -gt 5000 ]; then
    note "маршрутов очень много — похоже на режим route_exclude_address_set"
fi

# --- 2. Локальная сеть ------------------------------------------------------
head_ "Локальная сеть"
gw="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
if [ -n "${gw:-}" ]; then
    if ping -c 2 -t 3 "$gw" >/dev/null 2>&1; then
        ok "шлюз $gw отвечает"
    else
        bad "шлюз $gw не отвечает — локальная сеть сломана"
    fi
else
    note "не удалось определить шлюз по умолчанию"
fi

if dns-sd -t 2 -B _services._dns-sd._udp local >/dev/null 2>&1; then
    ok "mDNS (.local) отвечает"
else
    note "mDNS проверить не удалось (это не всегда признак поломки)"
fi

# --- 3. Разделение трафика --------------------------------------------------
head_ "Разделение трафика (главная проверка)"

# Сразу после загрузки системы туннель может быть ещё не готов: Wi-Fi
# поднимается, VLESS-сессия устанавливается, таблица маршрутов достраивается.
# Одна неудачная попытка в такой момент — не признак поломки, поэтому
# повторяем несколько раз с паузой.
fetch_retry() {
    local url="$1" attempts="${2:-3}" out=""
    for i in $(seq 1 "$attempts"); do
        out="$(curl -sS -m "$TIMEOUT" "$url" 2>/dev/null | tr -d '[:space:]"')"
        # Принимаем только настоящий внешний IPv4: HTML-заглушка или 127.x от сломанного
        # эхо-сервиса не должны засчитываться как ответ.
        if printf '%s' "$out" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' && [ "${out#127.}" = "$out" ]; then
            [ "$i" -gt 1 ] && printf '  \033[33m·\033[0m %s ответил с %d-й попытки\n' "$url" "$i"
            printf '%s' "$out"
            return 0
        fi
        [ "$i" -lt "$attempts" ] && sleep 3
    done
    return 1
}

ip_foreign="$(fetch_retry https://api.ipify.org 3)"
ip_russian="$(fetch_retry https://ip.beget.ru 3)"

if [ -z "$ip_foreign" ]; then
    bad "зарубежный сервис недоступен — интернет через туннель не работает"
else
    ok "зарубежный сервис (api.ipify.org) видит: ${ip_foreign}"
fi

if [ -z "$ip_russian" ]; then
    bad "российский сервис (ip.beget.ru) недоступен — прямой выход не работает"
else
    ok "российский сервис (ip.beget.ru) видит: ${ip_russian}"
fi

if [ -n "$ip_foreign" ] && [ -n "$ip_russian" ]; then
    if [ "$ip_foreign" = "$ip_russian" ]; then
        bad "ОБА сервиса видят один адрес (${ip_foreign}) — split-tunneling НЕ работает:"
        printf '      весь трафик идёт одним путём\n'
    else
        ok "адреса различаются — split-tunneling работает"
        printf '      через туннель: %s\n      напрямую:      %s\n' "$ip_foreign" "$ip_russian"
    fi
fi

# --- 4. Соответствие российского IP списку ---------------------------------
head_ "Проверка по rule-set"
if [ -x "$SING_BOX" ] && [ -f "${RULESET_DIR}/ru-ip.srs" ]; then
    if [ -n "${ip_russian:-}" ]; then
        out="$("$SING_BOX" rule-set match -f binary "${RULESET_DIR}/ru-ip.srs" "$ip_russian" 2>&1)"
        case "$out" in
            *"match rules"*) ok "ваш внешний адрес ${ip_russian} входит в RU-список" ;;
            *) note "адрес ${ip_russian} НЕ входит в RU-список — проверьте, что провайдер российский" ;;
        esac
    fi
    for ip in 77.88.8.8 87.250.250.242; do
        out="$("$SING_BOX" rule-set match -f binary "${RULESET_DIR}/ru-ip.srs" "$ip" 2>&1)"
        case "$out" in
            *"match rules"*) ok "якорь $ip в списке" ;;
            *) bad "якорь $ip ОТСУТСТВУЕТ — список повреждён" ;;
        esac
    done
    for ip in 8.8.8.8 1.1.1.1; do
        out="$("$SING_BOX" rule-set match -f binary "${RULESET_DIR}/ru-ip.srs" "$ip" 2>&1)"
        case "$out" in
            *"match rules"*) bad "анти-якорь $ip ПОПАЛ в список — список слишком широкий" ;;
            *) ok "анти-якорь $ip вне списка" ;;
        esac
    done
    prefixes="$(python3 -c "import json;print(json.load(open('${RULESET_DIR}/ru-ip.stats.json'))['prefixes'])" 2>/dev/null || echo "?")"
    ok "префиксов в списке: ${prefixes}"
else
    note "rule-set или sing-box недоступны, проверки списка пропущены"
fi

# --- 5. DNS -----------------------------------------------------------------
head_ "DNS"
ru_ip="$(dig +short +time=5 +tries=1 yandex.ru A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)"
if [ -n "$ru_ip" ]; then
    ok "yandex.ru резолвится в ${ru_ip}"
    if [ -x "$SING_BOX" ] && [ -f "${RULESET_DIR}/ru-ip.srs" ]; then
        out="$("$SING_BOX" rule-set match -f binary "${RULESET_DIR}/ru-ip.srs" "$ru_ip" 2>&1)"
        case "$out" in
            *"match rules"*) ok "  и этот адрес входит в RU-список (значит пойдёт напрямую)" ;;
            *) bad "  но адрес НЕ в RU-списке — российский домен уйдёт в туннель.
      Похоже, DNS для .ru-доменов идёт не через российский резолвер." ;;
        esac
    fi
else
    bad "yandex.ru не резолвится"
fi

if dig +short +time=5 +tries=1 google.com A >/dev/null 2>&1; then
    ok "зарубежные домены резолвятся"
else
    bad "google.com не резолвится"
fi

# --- 6. Демон ---------------------------------------------------------------
head_ "Служба"
if launchctl print system/com.singbox.daemon >/dev/null 2>&1; then
    pid="$(launchctl print system/com.singbox.daemon 2>/dev/null | awk '/^\tpid = /{print $3}')"
    if [ -n "${pid:-}" ]; then
        ok "LaunchDaemon работает, pid=${pid}"
    else
        note "LaunchDaemon зарегистрирован, но процесс не запущен"
    fi
else
    note "LaunchDaemon не загружен (нормально во время preflight)"
fi

if pgrep -x sing-box >/dev/null 2>&1; then
    ok "процесс sing-box найден: $(pgrep -x sing-box | tr '\n' ' ')"
else
    bad "процесс sing-box не найден"
fi

if pgrep -f Hiddify >/dev/null 2>&1; then
    note "ВНИМАНИЕ: Hiddify тоже запущен — два TUN одновременно конфликтуют за маршруты"
fi

# --- Итог -------------------------------------------------------------------
printf '\n\033[1m Итог: \033[32m%d успешно\033[0m, \033[31m%d провалено\033[0m, \033[33m%d пропущено\033[0m\n' \
    "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
