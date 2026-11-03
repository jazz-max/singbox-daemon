#!/bin/bash
# Кладёт на рабочий стол два ярлыка-приложения: «VPN вкл» и «VPN выкл».
# Двойной клик -> системное окно пароля администратора -> демон запускается/останавливается,
# в конце — уведомление с результатом. Терминал не открывается.
#
# Запускать от обычного пользователя (без sudo):
#   ./scripts/desktop-shortcuts.sh
# Удалить ярлыки: просто перетащить в корзину.
set -euo pipefail

LABEL="com.singbox.daemon"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
DESKTOP="${HOME}/Desktop"

if [[ $EUID -eq 0 ]]; then
    echo "Запускайте без sudo: ярлыки должны принадлежать вашему пользователю." >&2
    exit 1
fi
[[ -f "$PLIST" ]] || echo "Внимание: ${PLIST} не найден — сначала sudo ./scripts/install.sh --enable-daemon" >&2

build() {  # $1 — имя приложения, $2 — shell-команда под root, $3 — текст уведомления
    local app="${DESKTOP}/$1.app"
    rm -rf "$app"
    osacompile -o "$app" -e "
try
    do shell script \"$2\" with administrator privileges
    display notification \"$3\" with title \"sing-box\"
on error errMsg number errNum
    if errNum is not -128 then display alert \"sing-box: ошибка\" message errMsg as critical
end try"
    echo "создан: $app"
}

# Включить: снять возможный запрет (после emergency-reset), загрузить службу,
# а если уже загружена — перезапустить.
build "VPN вкл" \
    "launchctl enable system/${LABEL}; launchctl bootstrap system ${PLIST} 2>/dev/null || launchctl kickstart -k system/${LABEL}; sleep 2; launchctl print system/${LABEL} | grep -q 'state = running'" \
    "Туннель включён"

# Выключить: только выгрузить службу. Автозапуск НЕ отключается —
# после перезагрузки VPN поднимется сам.
build "VPN выкл" \
    "launchctl bootout system/${LABEL} 2>/dev/null || true" \
    "Туннель выключен"
