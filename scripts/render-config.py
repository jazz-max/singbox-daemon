#!/usr/bin/env python3
"""
Сборка рабочего конфига sing-box из шаблона и секретной части (подписки).

Шаблон (config/config.template.json) лежит в git и не содержит секретов.
Секреты (config/secrets/outbounds.json) в git не попадают — см. .gitignore.

Принимает секретный файл в любом из двух видов:
  * массив outbound-объектов:      [ {...}, {...} ]
  * целиком конфиг из Hiddify:     { "outbounds": [...], "route": {...}, ... }
                                    (берётся только ключ "outbounds")

Что делает со списком outbound'ов из подписки:
  * выбрасывает служебные (direct/block/dns) — они есть в шаблоне или больше
    не поддерживаются в sing-box 1.13 (тип dns удалён, block устарел);
  * следит, чтобы существовал outbound с тегом "proxy" — на него ссылается
    route.final в шаблоне. Если такого тега нет, создаёт selector "proxy",
    включающий все пригодные outbound'ы подписки.

Использование:
    render-config.py --template config/config.template.json \
                     --secrets config/secrets/outbounds.json \
                     --out config/config.generated.json
"""

import argparse
import json
import os
import sys

# Типы, которые нельзя переносить из подписки: в шаблоне свой direct,
# тип "dns" удалён в sing-box 1.13, "block" устарел (заменён action reject).
SKIP_TYPES = {"direct", "block", "dns"}
# Теги, которые в конфигах Hiddify носят служебный смысл.
SKIP_TAGS = {"direct", "direct-out", "bypass", "block", "dns-out", "dns_out"}

PROXY_TAG = "proxy"
DIRECT_TAG = "direct"


def die(msg):
    print(f"[render-config] ОШИБКА: {msg}", file=sys.stderr)
    sys.exit(1)


def log(msg):
    print(f"[render-config] {msg}", file=sys.stderr)


def load_secrets(path):
    if not os.path.exists(path):
        die(f"файл с подпиской не найден: {path}\n"
            f"           Выгрузите outbounds из Hiddify в формате sing-box "
            f"и положите сюда.")
    if os.path.getsize(path) == 0:
        die(f"файл с подпиской пуст: {path}")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as exc:
        die(f"файл с подпиской не разбирается как JSON: {exc}")

    if isinstance(data, list):
        outbounds = data
    elif isinstance(data, dict):
        if "outbounds" not in data:
            die("в файле с подпиской нет ключа 'outbounds'")
        outbounds = data["outbounds"]
    else:
        die("ожидался массив outbound'ов или объект с ключом 'outbounds'")

    if not isinstance(outbounds, list) or not outbounds:
        die("список outbounds пуст")
    return outbounds


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--template", required=True)
    ap.add_argument("--secrets", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if not os.path.exists(args.template):
        die(f"шаблон не найден: {args.template}")
    with open(args.template, encoding="utf-8") as fh:
        config = json.load(fh)

    raw_outbounds = load_secrets(args.secrets)
    log(f"в подписке outbound'ов: {len(raw_outbounds)}")

    # --- Фильтрация служебных ----------------------------------------------
    usable = []
    dropped = []
    for ob in raw_outbounds:
        if not isinstance(ob, dict):
            continue
        tag = ob.get("tag", "")
        typ = ob.get("type", "")
        if typ in SKIP_TYPES or tag in SKIP_TAGS:
            dropped.append(f"{tag or '<без тега>'} ({typ})")
            continue
        if not tag:
            dropped.append(f"<без тега> ({typ})")
            continue
        usable.append(ob)

    if dropped:
        log(f"отброшено служебных: {len(dropped)} — {', '.join(dropped[:8])}"
            + (" ..." if len(dropped) > 8 else ""))
    if not usable:
        die("после фильтрации не осталось ни одного пригодного outbound'а")

    tags = [ob["tag"] for ob in usable]
    log(f"пригодных outbound'ов: {len(usable)}")

    # --- Гарантируем наличие тега proxy -------------------------------------
    if PROXY_TAG not in tags:
        # Группирующие outbound'ы (selector/urltest) предпочтительнее
        # как содержимое нового селектора: они уже объединяют серверы.
        groups = [ob["tag"] for ob in usable if ob.get("type") in ("selector", "urltest")]
        members = groups if groups else tags
        selector = {
            "type": "selector",
            "tag": PROXY_TAG,
            "outbounds": members,
            "default": members[0],
        }
        usable.append(selector)
        log(f"тега '{PROXY_TAG}' в подписке не было — создан selector "
            f"'{PROXY_TAG}' из {len(members)} элементов, по умолчанию '{members[0]}'")
    else:
        log(f"тег '{PROXY_TAG}' найден в подписке — используется как есть")

    # --- Сборка -------------------------------------------------------------
    template_outbounds = config.get("outbounds", [])
    direct_entries = [ob for ob in template_outbounds if ob.get("tag") == DIRECT_TAG]
    if not direct_entries:
        die("в шаблоне нет outbound'а с тегом 'direct' — он обязателен, "
            "на него ссылаются правила split-tunneling")

    config["outbounds"] = usable + direct_entries

    # --- Проверки целостности ----------------------------------------------
    final_tags = {ob.get("tag") for ob in config["outbounds"]}
    route_final = config.get("route", {}).get("final")
    if route_final and route_final not in final_tags:
        die(f"route.final ссылается на '{route_final}', "
            f"но такого outbound'а нет среди {sorted(final_tags)}")

    # Все detour'ы DNS-серверов должны существовать
    for srv in config.get("dns", {}).get("servers", []):
        det = srv.get("detour")
        if det and det not in final_tags:
            die(f"DNS-сервер '{srv.get('tag')}' ссылается на detour '{det}', "
                f"которого нет среди outbound'ов")

    # Ссылки внутри selector/urltest
    for ob in config["outbounds"]:
        for ref in ob.get("outbounds", []):
            if ref not in final_tags:
                die(f"outbound '{ob.get('tag')}' ссылается на '{ref}', "
                    f"которого нет в конфиге")

    # --- Запись -------------------------------------------------------------
    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)
    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(config, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, args.out)

    log(f"собран конфиг: {args.out} "
        f"({len(config['outbounds'])} outbound'ов, режим 600)")
    log("ВАЖНО: файл содержит секреты подписки, в git он не попадает")


if __name__ == "__main__":
    main()
