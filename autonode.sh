if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен от root."
    exit 1
fi

echo "Обновление пакетов..."
apt update

#Отключение IPv6
echo "Отключить IPv6? (y/n) [по умолчанию y]:"
read DISABLE_IPV6
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

#Создание пользователя
echo "Введите имя пользователя:"
read USERNAME

if [ -z "$USERNAME" ]; then
    echo "Имя пользователя не может быть пустым."
    exit 1
fi

if id "$USERNAME" &>/dev/null; then
    echo "Пользователь с таким именем уже существует."
    exit 1
fi

echo "Создаем пользователя $USERNAME..."

if useradd -m -s /bin/bash "$USERNAME"; then
    echo "Пользователь $USERNAME успешно создан!"
else
    echo "Ошибка при создании пользователя $USERNAME."
    exit 1
fi

echo "Введите пароль для пользователя $USERNAME:"
until passwd "$USERNAME"; do
    echo "Попробуйте ещё раз."
done

#Добавляем пользователя в группу sudo
apt install sudo -y

if groups "$USERNAME" | grep -q '\bsudo\b'; then
    echo "Пользователь $USERNAME уже есть в группе sudo."
fi

usermod -aG sudo "$USERNAME"

if [ $? -eq 0 ]; then
    echo "Пользователь $USERNAME успешно добавлен в группу sudo."
else 
    echo "Ошибка при добавлении пользователя в группу sudo."
    exit 1
fi

#Запрет вход root через SSH
echo "Запрещаем вход root через SSH..."
SSHD="/etc/ssh/sshd_config"

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD"
grep -q "^PermitRootLogin" "$SSHD" || echo "PermitRootLogin no" >> "$SSHD"

#Настройка входа по ключу
echo "Введите ваш публичный SSH-ключ (или нажмите Enter, чтобы пропустить):"
read PUB_KEY

if [ -n "$PUB_KEY" ]; then
    #Проверяем, что ключ начинается с известного типа
    KEY_TYPE=$(echo "$PUB_KEY" | awk '{print $1}')
    case "$KEY_TYPE" in
        ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com)
            ;;
        *)
            echo "Похоже, это не публичный SSH-ключ. Убедитесь, что вы вставили содержимое файла .pub"
            exit 1
            ;;
    esac
    SSH_DIR="/home/$USERNAME/.ssh"
    mkdir -p "$SSH_DIR"
    echo "$PUB_KEY" >> "$SSH_DIR/authorized_keys"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"
    chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
    echo "Публичный ключ успешно добавлен."

    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD"

    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] || continue
        if grep -q "PasswordAuthentication" "$f"; then
            sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$f"
            echo "Исправлен файл: $f"
        fi
    done
else
    echo "Ключ не введён, пропускаем."
fi

echo "Перезапускаем SSH..."
systemctl restart sshd
echo "Запрещён вход root через SSH. SSH перезапущен."

#Настройка UFW
apt install ufw -y

validate_ip() {
    echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

validate_port() {
    echo "$1" | grep -Eq '^[0-9]+$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')

if [ -z "$CLIENT_IP" ]; then
    echo "Не удалось определить IP клиента. Введите вручную:"
    read CLIENT_IP
fi

if ! validate_ip "$CLIENT_IP"; then
    echo "Некорректный IP-адрес клиента: $CLIENT_IP"
    exit 1
fi

SERVER_IP=$(hostname -I | tr ' ' '\n' | grep -Ev ':' | head -1)
echo "IP сервера: $SERVER_IP"

# Запрос IP панели управления
echo "Введите IP панели управления:"
read PANEL_IP

if ! validate_ip "$PANEL_IP"; then
    echo "Некорректный IP панели: $PANEL_IP"
    exit 1
fi

# Запрос порта панели управления
echo "Введите порт панели управления [по умолчанию 3000]:"
read PANEL_PORT
PANEL_PORT=${PANEL_PORT:-3000}

if ! validate_port "$PANEL_PORT"; then
    echo "Некорректный порт: $PANEL_PORT"
    exit 1
fi

ufw allow from "$CLIENT_IP" to any port 22 proto tcp comment "SSH"
ufw insert 1 deny from "$SERVER_IP/22"
ufw allow 443/tcp comment "Caddy"
ufw allow from "$PANEL_IP" to any port "$PANEL_PORT" proto tcp comment "Panel"
ufw --force enable

echo "UFW настроен и включён."

#Настройка лимитов файловых дескрипторов
LIMITS_CONF="/etc/security/limits.conf"

if grep -q "^root soft nofile" "$LIMITS_CONF"; then
    echo "Лимиты уже настроены."
else
    cat >> "$LIMITS_CONF" << EOF
root soft nofile 1048576
root hard nofile 1048576
EOF
    echo "Лимиты файловых дескрипторов настроены."
fi

ulimit -n 1048576

#Установка remnanode
echo "Введите secret_key из панели remnawave:"
read KEY

echo "Повторите secret_key:"
read KEY_CONFIRM

if [ "$KEY" != "$KEY_CONFIRM" ]; then
    echo "Ключи не совпадают. Попробуйте снова."
    exit 1
fi

if [ -z "$KEY" ]; then
    echo "Ключ не может быть пустым."
    exit 1
fi

echo "Установка remnanode..."
bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh) @ install \
    --force --secret-key="$KEY"

echo "Настройка логов remnanode..."
remnanode setup-logs

#Настройка веб-сервера
bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install

#Установка WARP
bash <(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/wtm.sh) @ install-script

exit 0
