#!/usr/bin/env bash
#
# Обязательная проверка ПЕРЕД включением автозапуска.
#
# Поднимает sing-box на переднем плане, прогоняет healthcheck и гарантированно
# останавливает процесс на выходе — в том числе по Ctrl-C. После остановки
# проверяет, что маршруты вернулись в исходное состояние.
#
# Пока этот скрипт не отработал успешно, автозапуск включать нельзя:
# сломанный демон, стартующий при загрузке, оставит вас без сети.

set -uo pipefail

BIN_PATH="${BIN_PATH:-/usr/local/bin/sing-box}"
CONFIG="${CONFIG:-/etc/sing-box/config.json}"
LIB_DIR="${LIB_DIR:-/var/lib/sing-box}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ВНИМАНИЕ: BSD-mktemp в macOS требует, чтобы XXXXXX стояли в КОНЦЕ шаблона.
# Суффикс после них (…XXXXXX.log) приводит к "mkstemp failed: File exists".
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/singbox-preflight.XXXXXX")" || LOG_FILE="/tmp/singbox-preflight.$$"
: > "$LOG_FILE" || { printf 'Не удалось создать файл лога\n' >&2; exit 1; }

SB_PID=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    local rc=$?
    if [ -n "$SB_PID" ] && kill -0 "$SB_PID" 2>/dev/null; then
        printf '\n'
        log "Останавливаю sing-box (pid=$SB_PID)"
        # SIGTERM даёт sing-box снять маршруты штатно.
        # SIGKILL этого НЕ делает — маршруты останутся висеть в ядре.
        kill -TERM "$SB_PID" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$SB_PID" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$SB_PID" 2>/dev/null; then
            warn "не завершился за 10 с, отправляю SIGKILL"
            warn "после SIGKILL маршруты могут остаться — проверьте вывод ниже"
            kill -KILL "$SB_PID" 2>/dev/null
            sleep 1
        else
            ok "процесс завершён штатно"
        fi
        verify_restored
    fi
    printf '\nЛог этого прогона: %s\n' "$LOG_FILE"
    exit $rc
}
trap cleanup EXIT INT TERM

verify_restored() {
    log "Проверяю, что сеть вернулась в исходное состояние"
    local now_routes leftover
    now_routes="$(netstat -rn 2>/dev/null | wc -l | tr -d ' ')"
    printf '    маршрутов было: %s, стало: %s\n' "$ROUTES_BEFORE" "$now_routes"

    leftover="$(netstat -rn -f inet 2>/dev/null | grep -c '172\.18\.0\.1' || true)"
    if [ "${leftover:-0}" -gt 0 ]; then
        warn "в таблице остались маршруты через 172.18.0.1 — запустите:"
        printf '        sudo %s/emergency-reset.sh\n' "$SCRIPT_DIR"
    else
        ok "маршрутов туннеля не осталось"
    fi

    if curl -sS -m 10 -o /dev/null https://api.ipify.org 2>/dev/null; then
        ok "интернет работает"
    else
        warn "интернет НЕ отвечает — запустите emergency-reset.sh"
    fi
}

# --- Проверки ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "нужны права root. Запустите: sudo $0"
[ -x "$BIN_PATH" ] || die "не найден $BIN_PATH — сначала выполните install.sh"
[ -f "$CONFIG" ]   || die "не найден $CONFIG — сначала выполните install.sh"

log "Проверяю конфигурацию"
"$BIN_PATH" check -c "$CONFIG" || die "конфиг не проходит проверку"
ok "sing-box check пройдена"

# --- Конфликт с Hiddify -----------------------------------------------------
if pgrep -f Hiddify >/dev/null 2>&1; then
    printf '\n\033[1;33m'
    cat <<'EOF'
ВНИМАНИЕ: сейчас запущен Hiddify.

Он держит собственный TUN-интерфейс с auto_route. Два туннеля одновременно
борются за одни и те же маршруты по умолчанию, и результат непредсказуем:
проверки ниже покажут ерунду, а сеть может временно лечь.

Остановите Hiddify (выход из приложения, не только окно), затем вернитесь сюда.
EOF
    printf '\033[0m\n'
    read -r -p "Продолжить всё равно? [y/N] " ans
    case "${ans:-n}" in
        [yY]) warn "продолжаю при запущенном Hiddify — результатам проверок не верьте" ;;
        *) exit 1 ;;
    esac
fi

# --- Снимок состояния до запуска -------------------------------------------
ROUTES_BEFORE="$(netstat -rn 2>/dev/null | wc -l | tr -d ' ')"
IP_BEFORE="$(curl -sS -m 10 https://api.ipify.org 2>/dev/null || echo "недоступен")"
log "Состояние до запуска"
printf '    маршрутов: %s\n    внешний IP: %s\n' "$ROUTES_BEFORE" "$IP_BEFORE"

# --- Запуск -----------------------------------------------------------------
log "Запускаю sing-box (лог: $LOG_FILE)"
"$BIN_PATH" -D "$LIB_DIR" -c "$CONFIG" run >"$LOG_FILE" 2>&1 &
SB_PID=$!
sleep 1
kill -0 "$SB_PID" 2>/dev/null || { cat "$LOG_FILE"; die "sing-box не запустился"; }

log "Жду поднятия туннеля"
tun_up=0
for i in $(seq 1 30); do
    if ifconfig 2>/dev/null | grep -q 'inet 172\.18\.0\.1'; then
        tun_up=1
        ok "туннель поднялся за ${i} с"
        break
    fi
    kill -0 "$SB_PID" 2>/dev/null || { cat "$LOG_FILE"; die "sing-box упал при старте"; }
    sleep 1
done
[ "$tun_up" -eq 1 ] || { cat "$LOG_FILE"; die "туннель не поднялся за 30 с"; }

sleep 2

# --- Проверки ---------------------------------------------------------------
printf '\n\033[1;34m===================== ПРОВЕРКИ =====================\033[0m\n'
RULESET_DIR="${LIB_DIR}/rulesets" SING_BOX="$BIN_PATH" bash "${SCRIPT_DIR}/healthcheck.sh"
hc_rc=$?

printf '\n\033[1;34m====================================================\033[0m\n'
if [ "$hc_rc" -eq 0 ]; then
    printf '\033[1;32mВсе проверки пройдены.\033[0m\n'
else
    printf '\033[1;31mЕсть проваленные проверки — автозапуск включать рано.\033[0m\n'
    printf 'Последние строки лога:\n'
    tail -20 "$LOG_FILE" | sed 's/^/    /'
fi

# --- Что дальше -------------------------------------------------------------
cat <<EOF

sing-box сейчас РАБОТАЕТ на переднем плане (pid=$SB_PID).
Можно проверить руками в другом окне терминала: браузер, банк, рабочие сервисы.

Когда закончите — нажмите Ctrl-C или Enter здесь, и процесс будет остановлен
штатно (маршруты снимутся сами).
EOF

read -r -p $'\nНажмите Enter для остановки... ' _ || true
