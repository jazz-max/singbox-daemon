#!/usr/bin/env python3
"""
Валидация, агрегация и сборка sing-box rule-set (source format) из списков CIDR.

Читает один или несколько файлов со строками вида "1.2.3.0/24" (или голыми IP),
отбрасывает мусор, схлопывает перекрывающиеся и смежные префиксы, прогоняет
набор санити-проверок и пишет sing-box rule-set в source-формате (version 3).

Санити-проверки — главная часть. Битый или подменённый список, применённый
к живому конфигу, ломает сеть целиком, поэтому скрипт обязан упасть ДО того,
как файл попадёт в /var/lib/sing-box.

Использование:
    aggregate.py --out ru-ip.json --stats ru-ip.stats.json file1.txt [file2.txt ...]

Коды возврата:
    0 — успех
    2 — ошибка разбора аргументов / нет входных данных
    3 — провалена санити-проверка (список считается негодным)
"""

import argparse
import ipaddress
import json
import os
import sys

# --- Пороги санити-проверок ------------------------------------------------
# Ориентиры сняты с фактических данных на 2026-08-07: RIR-статистика RIPE NCC
# для RU даёт 8639 IPv4-префиксов после схлопывания и 45 185 088 адресов.
# Границы намеренно широкие: они ловят катастрофу (пустой файл, HTML-страницу
# вместо списка, обрезанную закачку, подмену на весь интернет), а не
# естественный дрейф списка в несколько процентов за год.
MIN_PREFIXES = 4_000
MAX_PREFIXES = 20_000
MIN_ADDRESSES = 25_000_000
MAX_ADDRESSES = 80_000_000

# Ни один префикс в страновом списке не может быть шире /8.
# 0.0.0.0/0 или 0.0.0.0/1 в списке = полный увод трафика мимо туннеля.
MIN_PREFIX_LEN = 8

# Якоря: эти адреса ОБЯЗАНЫ попасть в список. Если их нет — список
# либо не российский, либо повреждён. Проверяются по факту принадлежности
# любому из агрегированных префиксов.
REQUIRED_ANCHORS = [
    ("77.88.8.8", "Yandex DNS"),
    ("87.250.250.242", "yandex.ru"),
    ("217.69.139.202", "mail.ru"),
    ("5.255.255.242", "Yandex"),
    ("93.158.134.3", "Yandex"),
]

# Анти-якоря: эти адреса НЕ должны попасть в список. Если попали —
# список слишком широкий, и зарубежный трафик пойдёт мимо туннеля.
FORBIDDEN_ANCHORS = [
    ("8.8.8.8", "Google DNS"),
    ("1.1.1.1", "Cloudflare DNS"),
    ("9.9.9.9", "Quad9"),
    ("140.82.121.4", "GitHub"),
]

# Приватные и служебные диапазоны: в страновом списке им не место.
# Они обрабатываются отдельным правилом ip_is_private в route.rules,
# поэтому здесь просто вырезаются.
SPECIAL_RANGES = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24",
    "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24",
    "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
]


def log(msg):
    print(f"[aggregate] {msg}", file=sys.stderr)


def fail(msg):
    print(f"[aggregate] ОТКАЗ: {msg}", file=sys.stderr)
    sys.exit(3)


def load_file(path, only_v4=True):
    """Разбирает файл со списком CIDR. Возвращает (сети, статистику разбора)."""
    nets, bad, blank = [], 0, 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            # Комментарии в стиле '#' и ';', пустые строки
            if not line or line.startswith("#") or line.startswith(";"):
                blank += 1
                continue
            # Отбрасываем возможный inline-комментарий
            line = line.split("#", 1)[0].split(";", 1)[0].strip()
            if not line:
                blank += 1
                continue
            try:
                net = ipaddress.ip_network(line, strict=False)
            except ValueError:
                bad += 1
                continue
            if only_v4 and net.version != 4:
                continue
            nets.append(net)
    return nets, {"parsed": len(nets), "malformed": bad, "skipped": blank}


def strip_special(nets):
    """Вырезает приватные/служебные диапазоны из набора сетей."""
    import ipaddress as ip

    specials = [ip.ip_network(s) for s in SPECIAL_RANGES]
    result = []
    removed = 0
    for net in nets:
        if any(net.subnet_of(sp) for sp in specials):
            removed += 1
            continue
        result.append(net)
    return result, removed


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", help="файлы со списками CIDR")
    ap.add_argument("--out", required=True, help="куда писать rule-set (source JSON)")
    ap.add_argument("--stats", help="куда писать статистику (JSON)")
    ap.add_argument("--version", type=int, default=3,
                    help="версия формата rule-set (1..4; в sing-box 1.13 допустимы 1-4)")
    ap.add_argument("--allow-empty-anchors", action="store_true",
                    help="не падать при отсутствии якорных адресов (для отладки)")
    args = ap.parse_args()

    if args.version not in (1, 2, 3, 4):
        fail(f"версия формата {args.version} вне диапазона 1..4, поддерживаемого sing-box 1.13")

    # --- Загрузка -----------------------------------------------------------
    all_nets = []
    per_file = {}
    for path in args.inputs:
        if not os.path.exists(path):
            fail(f"входной файл не существует: {path}")
        if os.path.getsize(path) == 0:
            fail(f"входной файл пуст: {path}")
        nets, stats = load_file(path)
        if not nets:
            fail(f"из файла {path} не разобрано ни одного префикса "
                 f"(malformed={stats['malformed']}) — вероятно, вместо списка "
                 f"скачалась HTML-страница или файл обрезан")
        # Доля мусора выше 5% — признак того, что скачалось не то
        total_lines = stats["parsed"] + stats["malformed"]
        if total_lines and stats["malformed"] / total_lines > 0.05:
            fail(f"в файле {path} {stats['malformed']} нечитаемых строк из "
                 f"{total_lines} (>5%) — формат не тот, что ожидался")
        per_file[os.path.basename(path)] = stats
        all_nets.extend(nets)
        log(f"{os.path.basename(path)}: {stats['parsed']} префиксов, "
            f"мусор={stats['malformed']}")

    # --- Отсев служебных диапазонов ----------------------------------------
    all_nets, removed_special = strip_special(all_nets)
    if removed_special:
        log(f"вырезано приватных/служебных префиксов: {removed_special}")

    # --- Проверка на слишком широкие префиксы ------------------------------
    too_wide = [n for n in all_nets if n.prefixlen < MIN_PREFIX_LEN]
    if too_wide:
        fail(f"в списке есть префиксы шире /{MIN_PREFIX_LEN}: "
             f"{', '.join(str(n) for n in too_wide[:10])} — "
             f"такой список увёл бы мимо туннеля огромные куски интернета")

    # --- Агрегация ----------------------------------------------------------
    before = len(all_nets)
    collapsed = list(ipaddress.collapse_addresses(all_nets))
    after = len(collapsed)
    total_addresses = sum(n.num_addresses for n in collapsed)
    log(f"схлопывание: {before} -> {after} префиксов "
        f"({100 * (before - after) / before:.1f}% сокращение), "
        f"покрытие {total_addresses:,} адресов")

    # --- Санити: объём ------------------------------------------------------
    if after < MIN_PREFIXES:
        fail(f"после агрегации всего {after} префиксов, ожидалось не меньше "
             f"{MIN_PREFIXES} — список подозрительно мал")
    if after > MAX_PREFIXES:
        fail(f"после агрегации {after} префиксов, ожидалось не больше "
             f"{MAX_PREFIXES} — список подозрительно велик")
    if total_addresses < MIN_ADDRESSES:
        fail(f"покрытие {total_addresses:,} адресов меньше порога "
             f"{MIN_ADDRESSES:,}")
    if total_addresses > MAX_ADDRESSES:
        fail(f"покрытие {total_addresses:,} адресов больше порога "
             f"{MAX_ADDRESSES:,} — возможна подмена списка")

    # --- Санити: якоря ------------------------------------------------------
    def contains(addr_str):
        addr = ipaddress.ip_address(addr_str)
        # collapsed отсортирован; линейный поиск приемлем (тысячи элементов)
        return any(addr in net for net in collapsed)

    missing = [(a, why) for a, why in REQUIRED_ANCHORS if not contains(a)]
    present_forbidden = [(a, why) for a, why in FORBIDDEN_ANCHORS if contains(a)]

    if missing and not args.allow_empty_anchors:
        fail("в списке отсутствуют якорные российские адреса: " +
             ", ".join(f"{a} ({why})" for a, why in missing) +
             " — это не похоже на список российских сетей")
    if present_forbidden:
        fail("в списке присутствуют заведомо НЕроссийские адреса: " +
             ", ".join(f"{a} ({why})" for a, why in present_forbidden) +
             " — список слишком широкий, применять нельзя")

    log(f"якоря: {len(REQUIRED_ANCHORS)} на месте, "
        f"{len(FORBIDDEN_ANCHORS)} анти-якорей не задеты")

    # --- Запись rule-set ----------------------------------------------------
    ruleset = {
        "version": args.version,
        "rules": [
            {"ip_cidr": [str(n) for n in collapsed]}
        ],
    }
    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(ruleset, fh, ensure_ascii=False, separators=(",", ":"))
        fh.write("\n")
    os.replace(tmp, args.out)
    log(f"записан rule-set: {args.out} ({os.path.getsize(args.out):,} байт)")

    # --- Статистика ---------------------------------------------------------
    stats = {
        "prefixes_before_collapse": before,
        "prefixes": after,
        "addresses": total_addresses,
        "removed_special": removed_special,
        "per_file": per_file,
        "ruleset_version": args.version,
    }
    if args.stats:
        with open(args.stats, "w", encoding="utf-8") as fh:
            json.dump(stats, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
    print(json.dumps(stats, ensure_ascii=False))


if __name__ == "__main__":
    main()
