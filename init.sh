#!/bin/bash

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от имени root (через sudo)."
  exit 1
fi

echo "======================================================"
echo "    Автоматическая первоначальная настройка VPS       "
echo "======================================================"

# 1. Принудительный перевод зеркал на официальный архив Canonical (Без вопросов)
echo -e "\n[*] Проверка и переключение зеркал на archive.ubuntu.com..."
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    sed -i -E 's|URIs: https?://[^/]+/ubuntu/?|URIs: http://archive.ubuntu.com/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources
fi
if [ -f /etc/apt/sources.list ]; then
    sed -i -E 's|https?://[^/]+/ubuntu/?|http://archive.ubuntu.com/ubuntu/|g' /etc/apt/sources.list
fi
echo "-> Репозитории направлены на archive.ubuntu.com."

# 2. Обновляем систему (Без вопросов)
echo -e "\n[*] Авто-апдейт пакетной базы и системы..."
apt update && apt upgrade -y

# 3. Накатываем BBR и fq (Без вопросов)
echo -e "\n[*] Авто-настройка TCP BBR и диспетчера fq..."
if ! grep -q "net.core.default_qdisc = fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p
    echo "-> BBR успешно активирован."
else
    echo "-> BBR уже был настроен ранее."
fi

# 4. Вычищаем стартовый вывод терминала (Без вопросов)
echo -e "\n[*] Авто-очистка терминала от рекламы Canonical, ESM и анонсов апгрейда..."
chmod -x /etc/update-motd.d/00-header 2>/dev/null || true
chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
chmod -x /etc/update-motd.d/80-esm 2>/dev/null || true
chmod -x /etc/update-motd.d/85-fwupd 2>/dev/null || true
chmod -x /etc/update-motd.d/91-contract-ua-report 2>/dev/null || true
chmod -x /etc/update-motd.d/91-contract-ua-esm-status 2>/dev/null || true
chmod -x /etc/update-motd.d/91-release-upgrade 2>/dev/null || true
chmod -x /etc/update-motd.d/95-hwe-eol 2>/dev/null || true

# Отключение анонсов новой мажорной версии ОС
if [ -f /etc/update-manager/release-upgrades ]; then
    sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades
fi
rm -f /var/lib/ubuntu-release-upgrader/release-upgrade-available /run/motd.dynamic 2>/dev/null || true

# Накатываем фильтр ESM на скрипт обновлений
STAMP_SCRIPT="/etc/update-motd.d/90-updates-available"
if [ -f "$STAMP_SCRIPT" ]; then
    chmod +x "$STAMP_SCRIPT"
    sed -i 's|\[ ! -r "$stamp" \] || cat "$stamp"|\[ ! -r "$stamp" \] \|\| cat "$stamp" \| grep -ivE "esm\|expanded\|^$"|g' "$STAMP_SCRIPT"
fi

if [ -f /etc/default/motd-news ]; then
    sed -i 's/ENABLED=1/ENABLED=0/' /etc/default/motd-news
fi
echo -n "" > /etc/apt/apt.conf.d/20apt-esm-hook.conf 2>/dev/null || true
rm -f /var/lib/ubuntu-advantage/messages/* 2>/dev/null || true
echo "-> Вывод терминала приведен в идеальный вид."

# ======================================================
# БЛОК ИНТЕРАКТИВНЫХ ОПЦИЙ (2 ВОПРОСА)
# ======================================================
echo -e "\n======================================================"
echo "             Настройка кастомных параметров           "
echo "======================================================"

# Опция 1: Отключение IPv6
read -p "1. Полностью отключить IPv6 через sysctl? (y/n): " answer_ipv6
if [[ "$answer_ipv6" =~ ^[YyДд]$ ]]; then
    if ! grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
        sysctl -p
        echo "-> IPv6 отключен."
    else
        echo "-> IPv6 уже был отключен."
    fi
fi

# Опция 2: Изменение порта SSH + Разрешение входа по паролю для root
read -p "2. Изменить стандартный порт SSH (22)? (y/n): " answer_ssh
if [[ "$answer_ssh" =~ ^[YyДд]$ ]]; then
    read -p "   Введите кастомный порт SSH: " ssh_port
    if [[ "$ssh_port" =~ ^[0-9]+$ ]] && [ "$ssh_port" -ge 1 ] && [ "$ssh_port" -le 65535 ]; then
        # Конфиг SSHD drop-in
        mkdir -p /etc/ssh/sshd_config.d
        cat <<EOF > /etc/ssh/sshd_config.d/00-custom-ssh.conf
Port $ssh_port
PermitRootLogin yes
PasswordAuthentication yes
EOF

        # Обработка systemd socket activation с явным биндингом IPv4 и IPv6
        if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
            mkdir -p /etc/systemd/system/ssh.socket.d
            cat <<EOF > /etc/systemd/system/ssh.socket.d/listen.conf
[Socket]
ListenStream=
ListenStream=0.0.0.0:$ssh_port
ListenStream=[::]:$ssh_port
EOF
            systemctl daemon-reload
            systemctl restart ssh.socket
        fi

        # Открытие порта в UFW, если он активен
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
            ufw allow "$ssh_port"/tcp
        fi

        # Перезапуск службы SSH
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

        echo "-> Порт SSH изменен на $ssh_port, вход для root по паролю разрешен."
        echo "   [!] Не закрывай текущую сессию, пока не проверишь вход по порту $ssh_port в новом окне!"
    else
        echo "-> Некорректный порт. Пропущено."
    fi
fi

echo -e "\n======================================================"
echo "         Настройка завершена! Сервер готов к работе.  "
echo "======================================================"
