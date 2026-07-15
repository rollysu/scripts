#!/bin/bash

# Выход при любой непредвиденной ошибке
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен от root."
    exit 1
fi

echo "Обновление пакетов и установка базовых утилит..."
apt update && apt install -y curl sudo ufw

echo "Активация bbr..."
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# Отключение IPv6
read -p "Отключить IPv6? (y/n) [по умолчанию y]: " DISABLE_IPV6
DISABLE_IPV6=${DISABLE_IPV6:-y}

if [ "$DISABLE_IPV6" = "y" ]; then
    cat >> /etc/sysctl.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -p
    echo "IPv6 отключён."
else
    echo "IPv6 оставлен включённым."
fi

# Создание пользователя
read -p "Введите имя нового sudo-пользователя: " USERNAME

if [ -z "$USERNAME" ]; then
    echo "Имя пользователя не может быть пустым."
    exit 1
fi

if id "$USERNAME" &>/dev/null; then
    echo "Пользователь с таким именем уже существует."
    exit 1
fi

echo "Создаем пользователя $USERNAME..."
useradd -m -s /bin/bash "$USERNAME"

echo "Введите пароль для пользователя $USERNAME:"
until passwd "$USERNAME"; do
    echo "Попробуйте ещё раз."
done

# Добавляем пользователя в группу sudo
usermod -aG sudo "$USERNAME"
echo "Пользователь $USERNAME добавлен в группу sudo."

# Настройка SSH
SSHD="/etc/ssh/sshd_config"

# Запрещаем вход root в основном конфиге
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD"
grep -q "^PermitRootLogin" "$SSHD" || echo "PermitRootLogin no" >> "$SSHD"

# Чистим PermitRootLogin в дополнительных конфигах (drop-ins)
for f in /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$f" ] || continue
    if grep -q "PermitRootLogin" "$f"; then
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$f"
        echo "Root-доступ отключен в конфиге: $f"
    fi
done

# Настройка входа по SSH-ключу
read -p "Введите ваш публичный SSH-ключ (нажмите Enter, чтобы пропустить): " PUB_KEY

if [ -n "$PUB_KEY" ]; then
    KEY_TYPE=$(echo "$PUB_KEY" | awk '{print $1}')
    case "$KEY_TYPE" in
        ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com)
            SSH_DIR="/home/$USERNAME/.ssh"
            mkdir -p "$SSH_DIR"
            echo "$PUB_KEY" >> "$SSH_DIR/authorized_keys"
            chmod 700 "$SSH_DIR"
            chmod 600 "$SSH_DIR/authorized_keys"
            chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
            echo "Публичный ключ успешно добавлен."

            # Отключаем пароли, раз ключ успешно добавлен
            sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD"
            sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD"

            for f in /etc/ssh/sshd_config.d/*.conf; do
                [ -f "$f" ] || continue
                if grep -q "PasswordAuthentication" "$f"; then
                    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$f"
                    echo "Пароли отключены в конфиге: $f"
                fi
            done
            ;;
        *)
            echo "⚠️ Введен неверный формат ключа. Пропускаем настройку ключей (остается вход по паролю)."
            ;;
    esac
else
    echo "Ключ не введён, оставляем вход по паролю."
fi

echo "Перезапускаем SSH..."
systemctl restart sshd

# Настройка UFW
validate_ip() {
    echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

validate_port() {
    echo "$1" | grep -Eq '^[0-9]+$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Спрашиваем про ограничение SSH по IP
read -p "Ограничить доступ к SSH (порт 22) только для вашего текущего IP? (y/n) [по умолчанию n, безопасно]: " RESTRICT_SSH
RESTRICT_SSH=${RESTRICT_SSH:-n}

if [ "$RESTRICT_SSH" = "y" ]; then
    CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    if [ -z "$CLIENT_IP" ]; then
        read -p "Не удалось определить IP клиента. Введите ваш IP вручную: " CLIENT_IP
    fi

    if validate_ip "$CLIENT_IP"; then
        ufw allow from "$CLIENT_IP" to any port 22 proto tcp comment "SSH"
        echo "SSH разрешен только с IP $CLIENT_IP"
    else
        echo "Некорректный IP. SSH разрешен со всех IP в целях безопасности."
        ufw allow 22/tcp comment "SSH"
    fi
else
    ufw allow 22/tcp comment "SSH"
fi

ufw allow 443 comment "HTTPS"

# Запрос IP панели управления
read -p "Введите IP панели управления: " PANEL_IP
until validate_ip "$PANEL_IP"; do
    read -p "Некорректный IP. Введите IP панели управления еще раз: " PANEL_IP
done

# Запрос порта панели управления
read -p "Введите порт панели управления [по умолчанию 3000]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-3000}

until validate_port "$PANEL_PORT"; do
    read -p "Некорректный порт. Введите порт панели еще раз: " PANEL_PORT
done

ufw allow from "$PANEL_IP" to any port "$PANEL_PORT" proto tcp comment "Panel"

# Включаем файрвол
ufw --force enable
echo "UFW настроен и включён."

# Настройка лимитов файловых дескрипторов
LIMITS_CONF="/etc/security/limits.conf"

if grep -q "^root soft nofile" "$LIMITS_CONF"; then
    echo "Лимиты в limits.conf уже настроены."
else
    cat >> "$LIMITS_CONF" << EOF
root soft nofile 1048576
root hard nofile 1048576
$USERNAME soft nofile 1048576
$USERNAME hard nofile 1048576
EOF
    echo "Лимиты файловых дескрипторов настроены."
fi

# Настройка лимитов системных служб Systemd
if ! grep -q "DefaultLimitNOFILE" /etc/systemd/system.conf; then
    echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf
    systemctl daemon-reexec
fi

ulimit -n 1048576

# Настройка веб-сервера (Selfsteal)
echo "Запуск скрипта Selfsteal..."
bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install

# Установка remnanode
read -p "Введите secret_key ноды из панели: " KEY
read -p "Повторите secret_key: " KEY_CONFIRM

if [ "$KEY" != "$KEY_CONFIRM" ] || [ -z "$KEY" ]; then
    echo "Ключи не совпадают или пусты. Установка remnanode прервана."
    exit 1
fi

echo "Установка remnanode..."
bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh) @ install \
    --force --secret-key="$KEY" --port="$PANEL_PORT"

# Установка WARP
echo "Установка Cloudflare WARP..."
bash <(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/wtm.sh) install-warp

echo "🎉 Настройка сервера успешно завершена!"
exit 0