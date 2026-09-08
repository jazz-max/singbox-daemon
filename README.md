# sing-box как системный демон на macOS

Замена GUI-клиента Hiddify на системный LaunchDaemon: TUN-режим, split-tunneling
по IP-подсетям — российские сети идут напрямую, всё остальное через туннель.
Автозапуск до логина, без GUI, под root.

**Hiddify не трогается и остаётся рабочим запасным вариантом.**

Целевая система: macOS 14.7 (Sonoma), Apple M1 Pro, arm64, sing-box **1.13.16**.

Разбор каждого поля конфигурации — в [NOTES.md](NOTES.md).

---

## Порядок установки

Три шага, и второй пропускать нельзя.

```bash
# 1. Положить секреты подписки (в git не попадут)
mkdir -p config/secrets
#    Hiddify -> Экспорт -> формат sing-box -> сохранить как:
#    config/secrets/outbounds.json
#    Структура — см. config/outbounds.example.json

# 2. Разложить файлы, собрать список и конфиг. Демон НЕ запускается.
sudo ./scripts/install.sh

# 3. ОБЯЗАТЕЛЬНО: проверка в foreground.
#    Поднимет sing-box на переднем плане, прогонит проверки и остановит.
sudo ./scripts/preflight.sh

# 4. Только если шаг 3 прошёл чисто — включить автозапуск
sudo ./scripts/install.sh --enable-daemon
```

Почему шаг 3 отдельный: демон с битым конфигом, поднимающийся при загрузке,
оставит вас без сети до ручного вмешательства. `preflight.sh` гарантированно
останавливает процесс на выходе — в том числе по Ctrl-C — и проверяет, что
маршруты вернулись.

Перед проверкой **остановите Hiddify** (полный выход, не сворачивание окна).
Два TUN-интерфейса с `auto_route` борются за одни и те же маршруты; `preflight.sh`
это заметит и предупредит.

---

## Чеклист проверки

Автоматически — всё сразу:

```bash
./scripts/healthcheck.sh
```

Вручную, по пунктам вашего задания:

### 1. Российский IP идёт напрямую, остальное через прокси

```bash
curl -s https://api.ipify.org                  # зарубежный сервис -> должен показать IP прокси
curl -s https://yandex.ru/internet/api/v0/ip   # российский сервис  -> должен показать ваш IP
```

Адреса обязаны **различаться**. Совпали — split-tunneling не работает.

Полезный приём: снимите оба значения до установки, пока весь трафик идёт одним
путём. Тогда после запуска демона сразу видно, какой из адресов сменился.

Проверить, что конкретный адрес считается российским:

```bash
sing-box rule-set match -f binary /var/lib/sing-box/rulesets/ru-ip.srs 77.88.8.8
# match rules.[0]: ip_cidr=<binary>
```

### 2. Локальная сеть и .local живы

```bash
ping -c 3 192.168.1.1                              # шлюз
dns-sd -t 3 -B _services._dns-sd._udp local        # mDNS
ping -c 2 имя-устройства.local
```

За это отвечает правило `ip_is_private` — оно стоит выше правил туннеля.

### 3. DNS не течёт

```bash
dig +short yandex.ru A       # должен вернуть российский адрес
dig +short google.com A      # должен работать
```

Ключевая проверка — что российский домен резолвится **в российский** адрес:

```bash
ru_ip=$(dig +short yandex.ru A | head -1)
sing-box rule-set match -f binary /var/lib/sing-box/rulesets/ru-ip.srs "$ru_ip"
```

Если адрес НЕ в списке — DNS для `.ru` идёт мимо российского резолвера, и
российские сайты поедут через туннель. Разбор этого случая — в
[NOTES.md, раздел про DNS-компромисс](NOTES.md#главный-компромисс-dns-против-ip-правил).

### 4. После перезагрузки демон поднялся сам

```bash
sudo reboot
# после входа:
launchctl print system/com.singbox.daemon | head -20
./scripts/healthcheck.sh
```

Демон стартует до логина: он в `/Library/LaunchDaemons`, а не в `LaunchAgents`.

---

## Управление демоном

### Перезапуск

```bash
sudo launchctl kickstart -k system/com.singbox.daemon
```

`-k` убивает текущий процесс и запускает заново. Разрыв связи на 1–2 секунды.
Это основной способ — нужен всякий раз, когда туннель «залип»: например
провайдер обрубил и вернул интернет, сменилась сеть, ноутбук вышел из сна с
другим Wi-Fi.

**Почему `KeepAlive` в такой ситуации не спасает.** Он перезапускает процесс,
только если тот *завершился*. При обрыве канала sing-box жив и здоров — мёртвой
оказывается TCP-сессия до сервера, а этого launchd не видит. Поэтому пересоздать
соединение нужно вручную.

### Остановка и запуск

```bash
sudo launchctl bootout system/com.singbox.daemon      # остановить (туннель пропадёт)
sudo launchctl bootstrap system /Library/LaunchDaemons/com.singbox.daemon.plist
```

### Состояние

```bash
launchctl print system/com.singbox.daemon | grep -E 'state|pid|runs|last exit'
```

* `state = running` и растущий `runs` при неизменном `pid` — норма
* `runs` увеличивается сам по себе — демон падает и перезапускается, смотрите
  `/var/log/sing-box/sing-box.err.log`

### Служба не запускается после аварийного отката

`emergency-reset.sh` намеренно выполняет `launchctl disable`, чтобы сломанный
демон не поднялся при следующей загрузке. Этот запрет переживает
`bootout`/`bootstrap`: служба просто не стартует, без внятной ошибки.

Проверить и снять:

```bash
sudo launchctl print-disabled system | grep singbox
sudo launchctl enable system/com.singbox.daemon
sudo ./scripts/install.sh --enable-daemon
```

`install.sh --enable-daemon` снимает запрет сам, так что достаточно последней
команды.

### Туннель держится на preflight

Если `preflight.sh` был запущен и не закрыт, sing-box работает как его дочерний
процесс, а не как служба. Признак:

```bash
ps -o ppid= -p "$(pgrep -x sing-box)"   # родитель — bash ./preflight.sh
launchctl list | grep singbox           # пусто
```

Туннель в этом случае живёт ровно до закрытия терминала и не переживёт
перезагрузку. Закройте preflight (Enter или Ctrl-C) и поднимите службу:

```bash
sudo ./scripts/install.sh --enable-daemon
```

---

## Диагностика

### Состояние службы

```bash
launchctl print system/com.singbox.daemon        # состояние, pid, код выхода
sudo tail -f /var/log/sing-box/sing-box.err.log  # ошибки
sudo tail -50 /var/log/sing-box/sing-box.log     # обычный лог
```

### Таблица маршрутов

```bash
netstat -rn -f inet | head -20
netstat -rn | wc -l          # норма ~100; тысячи = режим route_exclude_address_set
```

При работающем туннеле в таблице должны быть ровно эти восемь строк
(так `auto_route` работает на macOS — см. NOTES.md):

```
1/8  2/7  4/6  8/5  16/4  32/3  64/2  128.0/1   ->  172.18.0.1
```

### Проверка конфигурации

```bash
sudo sing-box check -c /etc/sing-box/config.json
```

Учтите: `check` проверяет **не всё**. Например, ошибку
`detour to an empty direct outbound makes no sense` он пропускает — она
проявляется только при реальном запуске. Поэтому для проверки изменений
используйте `preflight.sh`, а не только `check`.

### Куда пойдёт конкретный домен

```bash
# доменный оверрайд (решает раньше IP-правил)
sing-box rule-set match /var/lib/sing-box/rulesets/ru-direct-domains.json example.ru

# список подсетей
sing-box rule-set match -f binary /var/lib/sing-box/rulesets/ru-ip.srs 5.255.255.242
```

### Подробный лог на время разбирательства

В `/etc/sing-box/config.json` временно поменяйте `"level": "warn"` на `"debug"`,
затем:

```bash
sudo launchctl kickstart -k system/com.singbox.daemon
```

Не забудьте вернуть `warn` — на `debug` лог растёт быстро.

---

## Аварийный откат

Работает без интернета, ничего не скачивает.

```bash
sudo ./scripts/emergency-reset.sh
```

Выгружает демон, останавливает процессы (сначала `SIGTERM`, чтобы sing-box снял
маршруты сам), вычищает оставшиеся маршруты, сбрасывает DNS-кеш и проверяет
связность. Автозапуск при этом **отключается**, чтобы демон не поднялся при
следующей загрузке.

### Если скрипт недоступен — вручную

```bash
sudo launchctl bootout system/com.singbox.daemon
sudo pkill -x sing-box

# снять маршруты auto_route (именно эти восемь на macOS)
for n in 1.0.0.0/8 2.0.0.0/7 4.0.0.0/6 8.0.0.0/5 \
         16.0.0.0/4 32.0.0.0/3 64.0.0.0/2 128.0.0.0/1; do
  sudo route -n delete -net $n
done

sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

**Почему маршруты приходится чистить руками.** sing-box снимает их в обработчике
штатной остановки. При `SIGKILL` или падении процесса обработчик не выполняется —
покрывающие маршруты остаются в ядре и указывают в исчезнувший интерфейс.

Совсем крайний случай — Wi-Fi off/on сбрасывает маршруты интерфейса:

```bash
sudo ifconfig en0 down && sudo ifconfig en0 up
```

Вернуть автозапуск после починки:

```bash
sudo launchctl enable system/com.singbox.daemon
sudo ./scripts/install.sh --enable-daemon
```

---

## Обновление списка подсетей

Автоматически — ежедневно в 04:30 через `com.singbox.ruleset-update`.
Если Mac спал, задание выполнится один раз после пробуждения.

Вручную:

```bash
sudo /usr/local/libexec/sing-box/build-ruleset.sh
```

Что происходит: скачать → проверить → схлопнуть → собрать source-JSON →
скомпилировать `.srs` → проверить якорными адресами → атомарно подменить.
Предыдущая версия сохраняется как `ru-ip.srs.prev`.

Перезапуск демона **не нужен**: локальный rule-set перечитывается при изменении
файла.

Список не заменяется, если новый не прошёл проверки — то есть битый список не
может сломать сеть. Проверки: объём (4000–20000 префиксов), покрытие
(25–80 млн адресов), отсутствие префиксов шире `/8`, доля нечитаемых строк,
наличие якорных российских адресов и отсутствие заведомо зарубежных.

Откатиться на предыдущую версию:

```bash
sudo cp /var/lib/sing-box/rulesets/ru-ip.srs.prev \
        /var/lib/sing-box/rulesets/ru-ip.srs
```

Журнал обновлений: `/var/log/sing-box/ruleset-update.log`

### Добавить домен в оверрайд

Оверрайдов два, они зеркальны друг другу:

| Файл | Для чего | Приоритет |
|---|---|---|
| `rulesets/force-proxy-domains.json` | домен **всегда** через туннель | выше |
| `rulesets/ru-direct-domains.json` | домен **всегда** напрямую | ниже |

Если российский сервис на не-`.ru` домене поехал через туннель — впишите его
в `ru-direct-domains.json`. Если зарубежный сервис, наоборот, утёк в direct —
в `force-proxy-domains.json`.

Второй случай возникает не только при явной ошибке. Правило `action: resolve`
в `route.rules` резолвит домен через `dns-ru` (Yandex DNS, см.
`default_domain_resolver`), а у крупных CDN есть российские ноды. Если такой
резолвер вернёт для зарубежного сервиса IP из российской подсети, домен
совпадёт с `ru-ip` и уйдёт напрямую — со всеми последствиями вроде
геоблокировки на стороне сервиса. `force-proxy-domains` стоит в правилах
**выше** и `resolve`, и `ru-ip`, поэтому решает по домену и до резолва.

Обновить:

```bash
sudo cp rulesets/force-proxy-domains.json rulesets/ru-direct-domains.json \
        /var/lib/sing-box/rulesets/
sudo launchctl kickstart -k system/com.singbox.daemon
```

Файлы в формате `source`, перекомпиляция не нужна. Оба влияют сразу на две
вещи: маршрутизацию и выбор DNS-резолвера.

---

## Замер двух архитектур

```bash
sudo ./scripts/benchmark-route-exclude.sh
```

Поочерёдно поднимает оба варианта и сравнивает: время старта, число маршрутов,
время обхода таблицы, отзывчивость, полноту очистки. Отчёт — в
`benchmark-results/`.

Расчётная разница известна заранее: 8639 RU-префиксов превращаются в
**21 652 маршрута** ядра при `route_exclude_address_set` против **8** при
`rule_set + direct`. Подробности — в [NOTES.md](NOTES.md#про-вариант-с-route_exclude_address_set).

---

## Удаление

```bash
sudo ./scripts/uninstall.sh                 # полностью, включая бинарник
sudo ./scripts/uninstall.sh --keep-binary   # оставить /usr/local/bin/sing-box
```

Возвращает систему в исходное состояние: выгружает службы, чистит маршруты,
удаляет `/etc/sing-box`, `/var/lib/sing-box`, `/var/log/sing-box`,
`/usr/local/libexec/sing-box`, plist-файлы и конфиг ротации логов.
Файлы проекта и `config/secrets/` остаются на месте. Hiddify не трогается.

---

## Что где лежит

### В системе

| Путь | Что |
|---|---|
| `/usr/local/bin/sing-box` | бинарник 1.13.16, sha256 проверяется при установке |
| `/etc/sing-box/config.json` | конфиг, `600 root:wheel` (содержит секреты) |
| `/var/lib/sing-box/` | рабочий каталог, `cache.db` |
| `/var/lib/sing-box/rulesets/` | `ru-ip.srs`, `ru-ip.srs.prev`, `ru-direct-domains.json`, `force-proxy-domains.json` |
| `/var/log/sing-box/` | логи |
| `/usr/local/libexec/sing-box/` | `build-ruleset.sh`, `aggregate.py` |
| `/Library/LaunchDaemons/com.singbox.daemon.plist` | демон |
| `/Library/LaunchDaemons/com.singbox.ruleset-update.plist` | обновление списка |
| `/etc/newsyslog.d/sing-box.conf` | ротация логов |

### В проекте

```
config/config.template.json    шаблон без секретов (в git)
config/outbounds.example.json  образец структуры подписки (в git)
config/secrets/outbounds.json  ваша подписка (в git НЕ попадает)
rulesets/ru-direct-domains.json  оверрайд «всегда напрямую» (в git)
rulesets/force-proxy-domains.json оверрайд «всегда через туннель» (в git)
scripts/                       установка, сборка списка, проверки, откат
launchd/                       plist-файлы и конфиг ротации
NOTES.md                       разбор каждого поля конфигурации
```

---

## Принятые решения

| Решение | Почему |
|---|---|
| Официальный бинарник, версия зафиксирована | в 1.14 удаляют legacy-DNS и `domain_strategy`; brew обновился бы сам и сломал конфиг на старте |
| `rule_set + direct` вместо `route_exclude_address_set` | 8 маршрутов вместо 21 652; список обновляется без перезапуска демона |
| Локальный rule-set вместо remote | нет проблемы курицы и яйца, валидация до применения, откат на предыдущую версию |
| Свой пайплайн вместо готового `.srs` | ipdeny, ipdeny-aggregated и ipverse дают идентичные 8639 префиксов (общий первоисточник — RIR-статистика RIPE NCC); свой пайплайн даёт контроль над валидацией |
| IPv6 отключён (`ipv4_only`) | у провайдера глобального IPv6 нет — только link-local на `en0`, связность не отвечает |
| `strict_route: false` | на macOS это поле не делает ничего (в `tun_darwin.go` не используется вообще) |
| Гибридный DNS | `.ru` через российский резолвер напрямую, остальное — DoH через туннель |
| fake-ip не используется | при нём `ip_cidr` по реальному адресу не матчится никогда |

Источник данных для списка: RIR-статистика RIPE NCC (через `ipverse/rir-ip`,
резерв — `ipdeny.com`). **antifilter.download не подходит** — это списки
заблокированных РКН ресурсов, а не российских сетей; проверено, там 80 подсетей
и 48 909 отдельных адресов, логика обратная нужной.
