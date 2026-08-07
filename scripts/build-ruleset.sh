#!/usr/bin/env bash
#
# Сборка rule-set с российскими IP-подсетями для sing-box.
#
#   скачать -> провалидировать -> агрегировать -> собрать source-JSON ->
#   -> скомпилировать .srs -> проверить якорями -> атомарно заменить
#
# Скрипт идемпотентен: повторный запуск просто пересобирает список.
# При любой ошибке действующий .srs остаётся нетронутым — заменяется он
# только после того, как новый файл прошёл все проверки.
#
# Запускается и вручную, и из LaunchDaemon по расписанию.
#
# ПРО «КУРИЦУ И ЯЙЦО»: её здесь нет by design. Список качает этот скрипт,
# а не sing-box (rule-set у нас local, не remote). Поэтому:
#   - демон работает   -> закачка идёт через туннель, это нормально;
#   - демон не работает -> TUN не поднят, трафик идёт напрямую, тоже нормально.
# Ни один из сценариев не зависит от содержимого самого списка.
# Если всё же нужна гарантированно прямая закачка (например, источник
# заблокирован снаружи РФ), выставьте DIRECT_FETCH=1 — скрипт проложит
# временные host-маршруты через физический шлюз и снимет их в trap.

set -euo pipefail

# --- Настройки (переопределяются переменными окружения) ---------------------
DEST_DIR="${DEST_DIR:-/var/lib/sing-box/rulesets}"
RULESET_NAME="${RULESET_NAME:-ru-ip}"
SING_BOX="${SING_BOX:-/usr/local/bin/sing-box}"
RULESET_VERSION="${RULESET_VERSION:-3}"
DIRECT_FETCH="${DIRECT_FETCH:-0}"
CURL_TIMEOUT="${CURL_TIMEOUT:-120}"
CURL_RETRIES="${CURL_RETRIES:-3}"

# Источники. Первый — основной, остальные — резерв по порядку.
# Все три происходят из RIR-статистики RIPE NCC и на 2026-08-07 дают
# идентичный результат (8639 префиксов после схлопывания).
SOURCES=(
  "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru/ipv4-aggregated.txt"
  "https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"
  "https://www.ipdeny.com/ipblocks/data/countries/ru.zone"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGGREGATE="${SCRIPT_DIR}/aggregate.py"

# Якоря для финальной проверки уже скомпилированного .srs.
# ВАЖНО: `sing-box rule-set match` возвращает код 0 и при совпадении,
# и при его отсутствии — проверять надо именно вывод.
ANCHORS_MUST_MATCH=(77.88.8.8 87.250.250.242 217.69.139.202)
ANCHORS_MUST_NOT_MATCH=(8.8.8.8 1.1.1.1 140.82.121.4)

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { printf '[%s] ОШИБКА: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/singbox-ruleset.XXXXXX")"
ADDED_ROUTES=()

cleanup() {
  local rc=$?
  # Снимаем временные маршруты, если ставили
  for host in "${ADDED_ROUTES[@]:-}"; do
    [ -n "$host" ] && route -n delete -host "$host" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK_DIR"
  exit $rc
}
trap cleanup EXIT INT TERM

# --- Проверки окружения -----------------------------------------------------
[ -x "$SING_BOX" ] || die "sing-box не найден или не исполняем: $SING_BOX"
[ -f "$AGGREGATE" ] || die "не найден aggregate.py: $AGGREGATE"
command -v python3 >/dev/null 2>&1 || die "не найден python3"

mkdir -p "$DEST_DIR"

# --- Опциональная прокладка прямых маршрутов --------------------------------
setup_direct_routes() {
  local gw
  gw="$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}')" || true
  [ -n "${gw:-}" ] || { log "ПРЕДУПРЕЖДЕНИЕ: не удалось определить шлюз, DIRECT_FETCH пропущен"; return 0; }
  log "DIRECT_FETCH=1, физический шлюз: $gw"
  local url host ips ip
  for url in "${SOURCES[@]}"; do
    host="$(printf '%s' "$url" | sed -E 's#^https?://([^/]+)/.*#\1#')"
    ips="$(dig +short "$host" A 2>/dev/null | grep -E '^[0-9]+\.' || true)"
    for ip in $ips; do
      if route -n add -host "$ip" "$gw" >/dev/null 2>&1; then
        ADDED_ROUTES+=("$ip")
        log "  временный прямой маршрут: $ip -> $gw"
      fi
    done
  done
}

[ "$DIRECT_FETCH" = "1" ] && setup_direct_routes

# --- Скачивание -------------------------------------------------------------
RAW_FILE="${WORK_DIR}/source.txt"
downloaded=""

for url in "${SOURCES[@]}"; do
  log "Скачиваю: $url"
  if curl -sS -L --fail \
          --max-time "$CURL_TIMEOUT" \
          --retry "$CURL_RETRIES" --retry-delay 2 \
          -o "$RAW_FILE" "$url"; then
    size="$(wc -c < "$RAW_FILE" | tr -d ' ')"
    if [ "$size" -lt 10000 ]; then
      log "  отвергнут: файл слишком мал (${size} байт)"
      continue
    fi
    log "  получено ${size} байт"
    downloaded="$url"
    break
  else
    log "  недоступен, пробую следующий источник"
  fi
done

[ -n "$downloaded" ] || die "ни один источник не доступен, список не обновлён"

# --- Агрегация и санити-проверки -------------------------------------------
SRC_JSON="${WORK_DIR}/${RULESET_NAME}.json"
STATS_JSON="${WORK_DIR}/${RULESET_NAME}.stats.json"

log "Валидирую и агрегирую"
if ! python3 "$AGGREGATE" \
      --out "$SRC_JSON" \
      --stats "$STATS_JSON" \
      --version "$RULESET_VERSION" \
      "$RAW_FILE" >/dev/null; then
  die "список не прошёл проверки, действующий .srs оставлен без изменений"
fi

prefixes="$(python3 -c "import json;print(json.load(open('$STATS_JSON'))['prefixes'])")"
addresses="$(python3 -c "import json;print(f\"{json.load(open('$STATS_JSON'))['addresses']:,}\")")"
log "Префиксов после агрегации: ${prefixes}, покрытие: ${addresses} адресов"

# --- Компиляция -------------------------------------------------------------
NEW_SRS="${WORK_DIR}/${RULESET_NAME}.srs"
log "Компилирую в бинарный формат"
"$SING_BOX" rule-set compile --output "$NEW_SRS" "$SRC_JSON" \
  || die "sing-box rule-set compile завершился с ошибкой"

[ -s "$NEW_SRS" ] || die "скомпилированный .srs пуст"

# Проверка магии заголовка: 'SRS' + байт версии формата
header="$(head -c 3 "$NEW_SRS")"
[ "$header" = "SRS" ] || die "у скомпилированного файла нет заголовка SRS"

srs_size="$(wc -c < "$NEW_SRS" | tr -d ' ')"
log "Скомпилировано: ${srs_size} байт"

# --- Валидация готового .srs якорями ---------------------------------------
log "Проверяю якорными адресами"
for ip in "${ANCHORS_MUST_MATCH[@]}"; do
  out="$("$SING_BOX" rule-set match -f binary "$NEW_SRS" "$ip" 2>&1 || true)"
  case "$out" in
    *"match rules"*) : ;;
    *) die "якорь $ip НЕ найден в новом списке — список негоден, замена отменена" ;;
  esac
done
for ip in "${ANCHORS_MUST_NOT_MATCH[@]}"; do
  out="$("$SING_BOX" rule-set match -f binary "$NEW_SRS" "$ip" 2>&1 || true)"
  case "$out" in
    *"match rules"*) die "анти-якорь $ip найден в новом списке — список слишком широкий, замена отменена" ;;
    *) : ;;
  esac
done
log "  якоря: ${#ANCHORS_MUST_MATCH[@]} на месте, ${#ANCHORS_MUST_NOT_MATCH[@]} анти-якорей не задеты"

# --- Атомарная замена с сохранением предыдущей версии -----------------------
TARGET="${DEST_DIR}/${RULESET_NAME}.srs"
PREV="${DEST_DIR}/${RULESET_NAME}.srs.prev"

if [ -f "$TARGET" ]; then
  if cmp -s "$NEW_SRS" "$TARGET"; then
    log "Список не изменился, замена не требуется"
    cp "$STATS_JSON" "${DEST_DIR}/${RULESET_NAME}.stats.json" 2>/dev/null || true
    log "Готово"
    exit 0
  fi
  cp -p "$TARGET" "$PREV"
  log "Предыдущая версия сохранена: $PREV"
fi

# mv в пределах одной ФС атомарен — sing-box никогда не увидит недописанный файл
install -m 0644 "$NEW_SRS" "${TARGET}.new"
mv -f "${TARGET}.new" "$TARGET"
cp "$SRC_JSON" "${DEST_DIR}/${RULESET_NAME}.json" 2>/dev/null || true
cp "$STATS_JSON" "${DEST_DIR}/${RULESET_NAME}.stats.json" 2>/dev/null || true

log "Установлено: $TARGET (${srs_size} байт, ${prefixes} префиксов)"
log "Источник: $downloaded"
log "Готово"
