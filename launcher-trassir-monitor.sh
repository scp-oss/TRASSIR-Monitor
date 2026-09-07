#!/bin/bash
# ============================================
# TRASSIR Monitor — Launcher v1.0
# Единая точка входа: установка/обновление/удаление дашборда и
# уведомлений (Telegram/Email), смена пароля администратора.
#
# Не дублирует логику самих установщиков — install-trassir-monitor.sh /
# install-telegram-notifier.sh / install-mail-notifier.sh / их
# анинсталлеры уже умеют всё нужное и уже проверены; этот скрипт только
# определяет, что уже установлено (по факту на диске/в systemd, а не по
# отдельному файлу-флагу — см. CLAUDE.md), и вызывает нужный из них.
#
# Работает и будучи скачанным в одиночку (сам подтягивает недостающие
# install-*.sh с GitHub), и будучи частью полного чекаута репозитория
# (тогда использует соседние файлы без обращения к сети, кроме случая
# "5. Update all", который всегда берёт свежую версию).
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/opt/trassir-monitor"
SELF_INSTALL_PATH="/usr/local/bin/trassir-monitor"
REPO_RAW_BASE="https://raw.githubusercontent.com/scp-oss/TRASSIR-Monitor/main"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите с правами root:${NC}"
    echo -e "  ${YELLOW}sudo bash $(basename "$0")${NC}"
    exit 1
fi

# ============================================
# ОПРЕДЕЛЕНИЕ ТЕКУЩЕГО СОСТОЯНИЯ (по факту, не по флагу)
# ============================================
dashboard_installed() {
    [ -f "$INSTALL_DIR/app/app.py" ] && [ -x "$INSTALL_DIR/venv/bin/python3" ]
}

telegram_installed() {
    [ -f "$INSTALL_DIR/app/tg_bot.py" ] || \
    systemctl list-unit-files 2>/dev/null | grep -q "trassir-tgbot"
}

email_installed() {
    [ -f "$INSTALL_DIR/app/mail_bot.py" ] || \
    systemctl list-unit-files 2>/dev/null | grep -q "trassir-mailbot"
}

_bool() { if "$1" >/dev/null 2>&1; then echo "true"; else echo "false"; fi; }

_press_enter() {
    echo ""
    read -p "Press Enter to return to the menu... " _dummy
}

# ============================================
# ПОЛУЧЕНИЕ НУЖНОГО install-*.sh / uninstall-*.sh
# ============================================
# force_fresh=0 (по умолчанию): берём соседний файл рядом с этим
# лаунчером, если он есть — без обращения к сети вообще. force_fresh=1
# (используется в "5. Update all"): всегда качаем свежую версию с
# GitHub, соседний файл в этом случае игнорируется намеренно — весь
# смысл обновления в том, чтобы получить актуальный код, а не тот, что
# случайно лежит рядом с лаунчером с момента его собственного скачивания.
#
# Возвращает путь через stdout. Специально НЕ сигнализирует
# "скачан временный / это локальный файл" через отдельную глобальную
# переменную — вызывается через command substitution ($(...)), которая
# всегда выполняется в подпроцессе, так что любое присваивание
# переменной внутри этой функции туда же и пропадает при возврате в
# вызывающий код. _run_installer() ниже поэтому решает, удалять ли
# результат, сравнивая сам путь с $SCRIPT_DIR/$name — а не полагаясь на
# такой флаг.
_get_script() {
    local name="$1" force_fresh="${2:-0}"
    local local_path="$SCRIPT_DIR/$name"

    if [ "$force_fresh" -eq 0 ] && [ -s "$local_path" ]; then
        printf '%s' "$local_path"
        return 0
    fi

    local tmp_path
    tmp_path=$(mktemp --suffix=".sh")
    echo -e "${CYAN}  Fetching $name from GitHub (main, latest)...${NC}" >&2
    if curl -fsSL --connect-timeout 15 --retry 3 --retry-delay 2 \
         -o "$tmp_path" "$REPO_RAW_BASE/$name" && [ -s "$tmp_path" ]; then
        printf '%s' "$tmp_path"
        return 0
    fi

    rm -f "$tmp_path"
    if [ -s "$local_path" ]; then
        echo -e "${YELLOW}  Could not download $name (no internet?) — using local copy: $local_path${NC}" >&2
        printf '%s' "$local_path"
        return 0
    fi

    echo -e "${RED}  ERROR: could not obtain $name — no internet, and no local copy${NC}" >&2
    echo -e "${RED}  next to this launcher ($SCRIPT_DIR/$name).${NC}" >&2
    return 1
}

_run_installer() {
    local name="$1" force_fresh="${2:-0}" path rc
    path=$(_get_script "$name" "$force_fresh") || return 1
    bash "$path"
    rc=$?
    # Удаляем только если это реально временный файл, скачанный только
    # что — никогда не трогаем соседний файл рядом с лаунчером.
    if [ "$path" != "$SCRIPT_DIR/$name" ]; then
        rm -f "$path"
    fi
    return $rc
}

# ============================================
# ПУНКТ 1 — DASHBOARD
# ============================================
do_install_dashboard() {
    if dashboard_installed; then
        echo -e "${YELLOW}Dashboard is already installed.${NC}"
        read -p "Reinstall / refresh it anyway? (y/N): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || return 0
    fi

    _run_installer "install-trassir-monitor.sh"
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo -e "${RED}Dashboard install failed (exit code $rc).${NC}"
        _press_enter
        return 1
    fi

    echo ""
    echo -e "${GREEN}Dashboard step complete.${NC}"

    # По запросу: после установки дашборда сразу предложить уведомления,
    # а не заставлять возвращаться в меню и выбирать пункты 2/3 отдельно.
    if ! telegram_installed; then
        echo ""
        read -p "Install Telegram notifications now? (y/N): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            _run_installer "install-telegram-notifier.sh"
        fi
    fi
    if ! email_installed; then
        echo ""
        read -p "Install Email notifications now? (y/N): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            _run_installer "install-mail-notifier.sh"
        fi
    fi
    _press_enter
}

# ============================================
# ПУНКТЫ 2/3 — УВЕДОМЛЕНИЯ ПО ОТДЕЛЬНОСТИ
# ============================================
_require_dashboard() {
    if dashboard_installed; then
        return 0
    fi
    echo -e "${RED}Dashboard is not installed yet.${NC}"
    echo -e "${YELLOW}Install it first: menu item 1.${NC}"
    _press_enter
    return 1
}

do_install_email() {
    _require_dashboard || return 1
    if email_installed; then
        echo -e "${YELLOW}Email notifications are already installed.${NC}"
        read -p "Reinstall / refresh anyway? (y/N): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || return 0
    fi
    _run_installer "install-mail-notifier.sh"
    _press_enter
}

do_install_telegram() {
    _require_dashboard || return 1
    if telegram_installed; then
        echo -e "${YELLOW}Telegram notifications are already installed.${NC}"
        read -p "Reinstall / refresh anyway? (y/N): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || return 0
    fi
    _run_installer "install-telegram-notifier.sh"
    _press_enter
}

# ============================================
# ПУНКТ 4 — СМЕНА ПАРОЛЯ АДМИНИСТРАТОРА
# ============================================
do_change_password() {
    _require_dashboard || return 1
    if command -v trassir-monitor-set-password >/dev/null 2>&1; then
        trassir-monitor-set-password
    else
        echo -e "${YELLOW}The 'trassir-monitor-set-password' command was not found${NC}"
        echo -e "${YELLOW}(this install predates it). Run '5. Update all' first, then retry.${NC}"
    fi
    _press_enter
}

# ============================================
# ПУНКТ 5 — ОБНОВИТЬ ВСЁ
# ============================================
do_update_all() {
    if ! dashboard_installed && ! telegram_installed && ! email_installed; then
        echo -e "${YELLOW}Nothing is installed yet — nothing to update.${NC}"
        _press_enter
        return 0
    fi

    echo -e "${CYAN}This re-runs the installer(s) for every component that is currently${NC}"
    echo -e "${CYAN}installed, fetching the latest version of each from GitHub.${NC}"
    echo -e "${GREEN}Dashboard update is safe and non-destructive — the database, all${NC}"
    echo -e "${GREEN}settings, and the admin password are preserved automatically.${NC}"
    if telegram_installed || email_installed; then
        echo -e "${YELLOW}Note: Telegram/Email notifier updates will ask you to re-enter${NC}"
        echo -e "${YELLOW}their credentials (bot token / chat IDs / SMTP login) — have them${NC}"
        echo -e "${YELLOW}ready before continuing.${NC}"
    fi
    echo ""
    read -p "Continue? (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 0

    if dashboard_installed; then
        echo ""
        echo -e "${CYAN}=== Updating Dashboard ===${NC}"
        _run_installer "install-trassir-monitor.sh" 1
    fi
    if telegram_installed; then
        echo ""
        echo -e "${CYAN}=== Updating Telegram notifications ===${NC}"
        _run_installer "install-telegram-notifier.sh" 1
    fi
    if email_installed; then
        echo ""
        echo -e "${CYAN}=== Updating Email notifications ===${NC}"
        _run_installer "install-mail-notifier.sh" 1
    fi

    echo ""
    echo -e "${GREEN}Update pass complete.${NC}"
    _press_enter
}

# ============================================
# ПУНКТ 6 — UNINSTALL
# ============================================
do_uninstall() {
    clear
    echo -e "${BOLD}TRASSIR-Monitor — Uninstall${NC}"
    echo ""
    echo "1.  Uninstall Dashboard (Telegram/Email are removed with it — they depend on it)"
    echo "2.  Uninstall Telegram notifications only"
    echo "3.  Uninstall Email notifications only"
    echo "4.  Uninstall everything"
    echo ""
    echo "0.  Back"
    echo ""
    read -p "Choice: " choice

    case "$choice" in
        1)
            if command -v trassir-monitor-uninstall >/dev/null 2>&1; then
                trassir-monitor-uninstall
            else
                echo -e "${YELLOW}Dashboard is not installed.${NC}"
            fi
            ;;
        2)
            if telegram_installed; then
                _run_installer "uninstall-telegram-bot.sh"
            else
                echo -e "${YELLOW}Telegram notifications are not installed.${NC}"
            fi
            ;;
        3)
            if email_installed; then
                _run_installer "uninstall-mail-notifier.sh"
            else
                echo -e "${YELLOW}Email notifications are not installed.${NC}"
            fi
            ;;
        4)
            # Уведомления снимаем ДО дашборда — их анинсталляторы бэкапят
            # логи/конфиг внутри $INSTALL_DIR, которого после
            # trassir-monitor-uninstall уже не будет.
            if telegram_installed; then
                _run_installer "uninstall-telegram-bot.sh"
            fi
            if email_installed; then
                _run_installer "uninstall-mail-notifier.sh"
            fi
            if command -v trassir-monitor-uninstall >/dev/null 2>&1; then
                trassir-monitor-uninstall
            fi
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            ;;
    esac
    _press_enter
}

# ============================================
# УСТАНОВКА СЕБЯ КАК ГЛОБАЛЬНОЙ КОМАНДЫ (удобство, не обязательно)
# ============================================
# Тихо, без вопросов — просто чтобы после первого запуска через
# wget+bash это меню было доступно короткой командой `sudo
# trassir-monitor`, без необходимости помнить, куда скачался сам файл.
_self_install() {
    local self_path
    self_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    [ "$self_path" = "$SELF_INSTALL_PATH" ] && return 0
    if ! cmp -s "$self_path" "$SELF_INSTALL_PATH" 2>/dev/null; then
        cp -f "$self_path" "$SELF_INSTALL_PATH" 2>/dev/null && \
        chmod +x "$SELF_INSTALL_PATH" 2>/dev/null
    fi
}
_self_install

# ============================================
# ГЛАВНОЕ МЕНЮ
# ============================================
show_menu() {
    clear
    echo -e "${GREEN}${BOLD}TRASSIR-Monitor v13.0${NC}"
    echo ""
    printf "%-3s [%-5s] %s\n" "1." "$(_bool dashboard_installed)" "Install Dashboard"
    printf "%-3s [%-5s] %s\n" "2." "$(_bool email_installed)" "Install Email notification"
    printf "%-3s [%-5s] %s\n" "3." "$(_bool telegram_installed)" "Install Telegram notification"
    echo ""
    echo "4.  Change admin passwd"
    echo ""
    echo "5.  Update all"
    echo "6.  Uninstall"
    echo ""
    echo "0.  Exit"
    echo ""
}

while true; do
    show_menu
    read -p "Choice: " CHOICE
    case "$CHOICE" in
        1) do_install_dashboard ;;
        2) do_install_email ;;
        3) do_install_telegram ;;
        4) do_change_password ;;
        5) do_update_all ;;
        6) do_uninstall ;;
        0) echo "Bye."; exit 0 ;;
        *) echo -e "${RED}Invalid choice${NC}"; sleep 1 ;;
    esac
done
