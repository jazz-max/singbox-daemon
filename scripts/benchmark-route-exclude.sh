#!/usr/bin/env bash
#
# Сравнительный замер двух способов исключить российские сети из туннеля:
#
#   (а) route_exclude_address_set у tun-инбаунда
#       — исключение на уровне маршрутов ядра: sing-box вычитает RU-подсети
#         из покрывающих диапазонов и ставит в ядро то, что осталось.
#         Расчётно это 21 652 маршрута вместо 8.
#
#   (б) правило route с rule_set + outbound direct
#       — решение принимает сам sing-box, таблица маршрутов не растёт.
#
# Меряется: время старта, число маршрутов, время обхода таблицы, отзывчивость
# сети под нагрузкой, корректность разделения трафика и полнота очистки
# маршрутов при остановке.
#
# Скрипт поочерёдно поднимает оба варианта на переднем плане и гарантированно
# останавливает их (в том числе по Ctrl-C). Между вариантами сеть возвращается
# в исходное состояние.
#
# Запуск:  sudo ./scripts/benchmark-route-exclude.sh
# Результат: benchmark-results/<дата>.txt рядом с проектом

set -uo pipefail

BIN_PATH="${BIN_PATH:-/usr/local/bin/sing-box}"
CONFIG="${CONFIG:-/etc/sing-box/config.json}"
LIB_DIR="${LIB_DIR:-/var/lib/sing-box}"
TUN_ADDR="${TUN_ADDR:-172.18.0.1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${PROJECT_DIR}/benchmark-results"
STAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
REPORT="${RESULTS_DIR}/${STAMP}.txt"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/singbox-bench.XXXXXX")"
SB_PID=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" | tee -a "$REPORT"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*" | tee -a "$REPORT"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*" | tee -a "$REPORT"; }
say()  { printf '%s\n' "$*" | tee -a "$REPORT"; }
die()  { printf '\033[1;31mОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

stop_sb() {
    [ -n "$SB_PID" ] || return 0
    kill -0 "$SB_PID" 2>/dev/null || { SB_PID=""; return 0; }
    kill -TERM "$SB_PID" 2>/dev/null
    local t0 t1
    t0="$(python3 -c 'import time;print(time.time())')"
    for _ in $(seq 1 40); do
        kill -0 "$SB_PID" 2>/dev/null || break
        sleep 0.25
    done
    t1="$(python3 -c 'import time;print(time.time())')"
    if kill -0 "$SB_PID" 2>/dev/null; then
        warn "не завершился за 10 с — SIGKILL (маршруты останутся!)"
        kill -KILL "$SB_PID" 2>/dev/null
        sleep 1
    fi
    STOP_SECONDS="$(python3 -c "print(f'{$t1-$t0:.2f}')")"
    SB_PID=""
}

cleanup() {
    local rc=$?
    stop_sb
    # Подчищаем на случай аварийного выхода
    for net in 1.0.0.0/8 2.0.0.0/7 4.0.0.0/6 8.0.0.0/5 16.0.0.0/4 32.0.0.0/3 64.0.0.0/2 128.0.0.0/1; do
        route -n delete -net "$net" >/dev/null 2>&1
    done
    rm -rf "$WORK"
    printf '\nОтчёт: %s\n' "$REPORT"
    exit $rc
}
trap cleanup EXIT INT TERM

[ "$(id -u)" -eq 0 ] || die "нужны права root. Запустите: sudo $0"
[ -x "$BIN_PATH" ] || die "не найден $BIN_PATH"
[ -f "$CONFIG" ]   || die "не найден $CONFIG"
[ -f "${LIB_DIR}/rulesets/ru-ip.srs" ] || die "не найден ru-ip.srs"

mkdir -p "$RESULTS_DIR"
: > "$REPORT"

if pgrep -f Hiddify >/dev/null 2>&1; then
    die "запущен Hiddify — остановите его, иначе замеры бессмысленны"
fi

say "==============================================================="
say " Замер: route_exclude_address_set против rule_set + direct"
say " Дата: $(date '+%Y-%m-%d %H:%M:%S')"
say " macOS $(sw_vers -productVersion), $(uname -m)"
say " sing-box $("$BIN_PATH" version | awk '/^sing-box version/{print $3}')"
say "==============================================================="

# --- Подготовка конфигов ----------------------------------------------------
python3 - "$CONFIG" "$WORK" <<'PY'
import json, sys
cfg_path, work = sys.argv[1], sys.argv[2]
cfg = json.load(open(cfg_path))

# Вариант (б): как есть
json.dump(cfg, open(f"{work}/config-b.json", "w"), ensure_ascii=False, indent=2)

# Вариант (а): исключение на уровне маршрутов ядра
a = json.loads(json.dumps(cfg))
for ib in a["inbounds"]:
    if ib.get("type") == "tun":
        ib["route_exclude_address_set"] = ["ru-ip"]
# Правило по rule_set больше не нужно: RU-трафик вообще не заходит в sing-box
a["route"]["rules"] = [r for r in a["route"]["rules"]
                       if r.get("rule_set") != ["ru-ip"]]
json.dump(a, open(f"{work}/config-a.json", "w"), ensure_ascii=False, indent=2)
print("конфиги подготовлены")
PY

"$BIN_PATH" check -c "${WORK}/config-a.json" || die "вариант (а) не проходит check"
"$BIN_PATH" check -c "${WORK}/config-b.json" || die "вариант (б) не проходит check"
ok "оба варианта проходят sing-box check"

# --- Базовое состояние ------------------------------------------------------
BASE_ROUTES="$(netstat -rn 2>/dev/null | wc -l | tr -d ' ')"
GW="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
log "Исходное состояние"
say "    маршрутов: ${BASE_ROUTES}"
say "    шлюз: ${GW:-неизвестен}"

measure_netstat() {
    local t0 t1
    t0="$(python3 -c 'import time;print(time.time())')"
    netstat -rn >/dev/null 2>&1
    t1="$(python3 -c 'import time;print(time.time())')"
    python3 -c "print(f'{($t1-$t0)*1000:.0f}')"
}

measure_ping() {
    ping -c 5 -t 5 "${GW:-192.168.1.1}" 2>/dev/null \
        | awk -F'/' '/round-trip|avg/ {print $5; exit}'
}

measure_curl() {
    curl -sS -m 20 -o /dev/null -w '%{time_total}' https://api.ipify.org 2>/dev/null || echo "н/д"
}

BASE_NETSTAT_MS="$(measure_netstat)"
BASE_PING="$(measure_ping)"
say "    обход netstat -rn: ${BASE_NETSTAT_MS} мс"
say "    ping шлюза (avg): ${BASE_PING:-н/д} мс"

# --- Прогон одного варианта -------------------------------------------------
run_variant() {
    local name="$1" cfg="$2"
    local t_start t_tun t_routes routes_after netstat_ms ping_avg curl_s
    local ip_foreign ip_russian leftover

    say ""
    say "---------------------------------------------------------------"
    log "ВАРИАНТ ${name}"
    say "---------------------------------------------------------------"

    t_start="$(python3 -c 'import time;print(time.time())')"
    "$BIN_PATH" -D "$LIB_DIR" -c "$cfg" run >"${WORK}/${name}.log" 2>&1 &
    SB_PID=$!

    # Момент появления интерфейса
    local tun_ok=0
    for _ in $(seq 1 120); do
        if ifconfig 2>/dev/null | grep -q "inet ${TUN_ADDR}"; then tun_ok=1; break; fi
        kill -0 "$SB_PID" 2>/dev/null || break
        sleep 0.25
    done
    t_tun="$(python3 -c 'import time;print(time.time())')"
    if [ "$tun_ok" -ne 1 ]; then
        warn "туннель не поднялся, лог:"; tail -10 "${WORK}/${name}.log" | tee -a "$REPORT"
        stop_sb; return 1
    fi
    say "    время до появления интерфейса: $(python3 -c "print(f'{$t_tun-$t_start:.2f}')") с"

    # Момент стабилизации таблицы маршрутов: ждём, пока перестанет расти
    local prev=-1 cur=0 stable=0
    for _ in $(seq 1 240); do
        cur="$(netstat -rn 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$cur" -eq "$prev" ]; then
            stable=$((stable+1))
            [ "$stable" -ge 3 ] && break
        else
            stable=0
        fi
        prev="$cur"
        sleep 0.25
    done
    t_routes="$(python3 -c 'import time;print(time.time())')"
    routes_after="$cur"

    say "    время до стабилизации маршрутов: $(python3 -c "print(f'{$t_routes-$t_start:.2f}')") с"
    say "    маршрутов в таблице: ${routes_after} (было ${BASE_ROUTES}, прирост $((routes_after-BASE_ROUTES)))"

    netstat_ms="$(measure_netstat)"
    say "    обход netstat -rn: ${netstat_ms} мс (базово ${BASE_NETSTAT_MS} мс)"

    ping_avg="$(measure_ping)"
    say "    ping шлюза (avg): ${ping_avg:-н/д} мс (базово ${BASE_PING:-н/д} мс)"

    curl_s="$(measure_curl)"
    say "    первый HTTPS-запрос: ${curl_s} с"

    ip_foreign="$(curl -sS -m 20 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
    ip_russian="$(curl -sS -m 20 https://ip.beget.ru 2>/dev/null | tr -d '[:space:]"')"
    say "    зарубежный сервис видит: ${ip_foreign:-недоступен}"
    say "    российский сервис видит: ${ip_russian:-недоступен}"
    if [ -n "$ip_foreign" ] && [ -n "$ip_russian" ] && [ "$ip_foreign" != "$ip_russian" ]; then
        ok "разделение трафика работает"
    else
        warn "разделение НЕ подтвердилось"
    fi

    # Остановка и проверка очистки
    STOP_SECONDS=""
    stop_sb
    say "    время штатной остановки: ${STOP_SECONDS:-н/д} с"
    sleep 1

    leftover="$(netstat -rn 2>/dev/null | wc -l | tr -d ' ')"
    say "    маршрутов после остановки: ${leftover} (исходно ${BASE_ROUTES})"
    if [ "$leftover" -le "$((BASE_ROUTES + 2))" ]; then
        ok "маршруты вычищены полностью"
    else
        warn "осталось лишних маршрутов: $((leftover-BASE_ROUTES)) — очистка неполная"
    fi

    if curl -sS -m 15 -o /dev/null https://api.ipify.org 2>/dev/null; then
        ok "сеть после остановки работает"
    else
        warn "сеть после остановки НЕ работает"
    fi

    # Итоги в переменные для сводки
    eval "RES_${name}_ROUTES=\$routes_after"
    eval "RES_${name}_START=\$(python3 -c \"print(f'{\$t_routes-\$t_start:.2f}')\")"
    eval "RES_${name}_NETSTAT=\$netstat_ms"
    eval "RES_${name}_PING=\${ping_avg:-н/д}"
    eval "RES_${name}_STOP=\${STOP_SECONDS:-н/д}"
    eval "RES_${name}_LEFT=\$((leftover-BASE_ROUTES))"

    sleep 3
}

run_variant "B" "${WORK}/config-b.json"
run_variant "A" "${WORK}/config-a.json"

# --- Сводка -----------------------------------------------------------------
say ""
say "==============================================================="
say " СВОДКА"
say "==============================================================="
printf '%-38s %14s %14s\n' "показатель" "(б) rule_set" "(а) exclude_set" | tee -a "$REPORT"
printf '%-38s %14s %14s\n' "--------------------------------------" "--------------" "--------------" | tee -a "$REPORT"
printf '%-38s %14s %14s\n' "маршрутов в таблице"        "${RES_B_ROUTES:-н/д}"  "${RES_A_ROUTES:-н/д}"  | tee -a "$REPORT"
printf '%-38s %14s %14s\n' "старт до стабилизации, с"   "${RES_B_START:-н/д}"   "${RES_A_START:-н/д}"   | tee -a "$REPORT"
printf '%-38s %14s %14s\n' "обход netstat -rn, мс"      "${RES_B_NETSTAT:-н/д}" "${RES_A_NETSTAT:-н/д}" | tee -a "$REPORT"
printf '%-38s %14s %14s\n' "ping шлюза avg, мс"         "${RES_B_PING:-н/д}"    "${RES_A_PING:-н/д}"    | tee -a "$REPORT"
printf '%-38s %14s %14s\n' "штатная остановка, с"       "${RES_B_STOP:-н/д}"    "${RES_A_STOP:-н/д}"    | tee -a "$REPORT"
printf '%-38s %14s %14s\n' "маршрутов осталось после"   "${RES_B_LEFT:-н/д}"    "${RES_A_LEFT:-н/д}"    | tee -a "$REPORT"

say ""
say "Напоминание про вариант (а): на macOS набор исключаемых подсетей"
say "снимается снимком при старте. Обновление rule-set НЕ пересчитывает"
say "маршруты — callback регистрируется только при auto_redirect, а он"
say "существует только на Linux. То есть после обновления списка вариант (а)"
say "требует перезапуска демона, а вариант (б) подхватывает файл сам."
