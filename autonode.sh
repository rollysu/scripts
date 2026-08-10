#!/bin/bash

set -e

STATE_DIR="/var/lib/server-setup"
STATE_FILE="$STATE_DIR/completed_steps"
VARS_FILE="$STATE_DIR/vars.env"

mkdir -p "$STATE_DIR"
touch "$STATE_FILE" "$VARS_FILE"
chmod 700 "$STATE_DIR"
chmod 600 "$STATE_FILE" "$VARS_FILE"

if [ "${1:-}" = "--reset" ]; then
    echo "Сбрасываем сохранённое состояние скрипта..."
    : > "$STATE_FILE"
    : > "$VARS_FILE"
    echo "Состояние очищено. Запустите скрипт заново без --reset."
    exit 0
fi

source "$VARS_FILE"

trap 'echo "❌ Скрипт прерван из-за ошибки. Ничего страшного: просто запустите его ещё раз — выполнение продолжится с прерванного шага (уже выполненные шаги будут пропущены)."' ERR

save_var() {
    local name="$1"
    local value="$2"
    sed -i "/^${name}=/d" "$VARS_FILE" 2>/dev/null || true
    printf '%s=%q\n' "$name" "$value" >> "$VARS_FILE"
}

scrub_var() {
    local name="$1"
    sed -i "/^${name}=/d" "$VARS_FILE" 2>/dev/null || true
    unset "$name" 2>/dev/null || true
}

is_step_done() {
    grep -qxF "$1" "$STATE_FILE"
}

mark_step_done() {
    echo "$1" >> "$STATE_FILE"
}

run_step() {
    local step_name="$1"
    local step_func="$2"
    if is_step_done "$step_name"; then
        echo "✅ Шаг '$step_name' уже выполнен ранее — пропускаем."
        return 0
    fi
    echo "▶️  Выполняем шаг: $step_name"
    "$step_func"
    mark_step_done "$step_name"
    echo "✔️  Шаг '$step_name' завершён и сохранён."
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен от root."
    exit 1
fi

add_to_sysctl() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}" /etc/sysctl.conf; then
        sed -i "s|^${key}.*|${key} = ${value}|" /etc/sysctl.conf
    else
        echo "${key} = ${value}" >> /etc/sysctl.conf
    fi
}

validate_ip() {
    echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

validate_port() {
    echo "$1" | grep -Eq '^[0-9]+$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

step_base_packages() {
    echo "Обновление пакетов и установка базовых утилит..."
    apt update && apt install -y curl sudo ufw
}

step_bbr() {
    echo "Активация bbr..."
    add_to_sysctl "net.core.default_qdisc" "fq"
    add_to_sysctl "net.ipv4.tcp_congestion_control" "bbr"
    sysctl -p
}

step_ipv6() {
    if [ -z "${DISABLE_IPV6:-}" ]; then
        read -p "Отключить IPv6? (y/n) [по умолчанию y]: " DISABLE_IPV6
        DISABLE_IPV6=${DISABLE_IPV6:-y}
        save_var "DISABLE_IPV6" "$DISABLE_IPV6"
    else
        echo "Используем ранее сохранённый ответ: DISABLE_IPV6=$DISABLE_IPV6"
    fi

    if [ "$DISABLE_IPV6" = "y" ]; then
        add_to_sysctl "net.ipv6.conf.all.disable_ipv6" "1"
        add_to_sysctl "net.ipv6.conf.default.disable_ipv6" "1"
        add_to_sysctl "net.ipv6.conf.lo.disable_ipv6" "1"
        sysctl -p
        echo "IPv6 отключён."
    else
        echo "IPv6 оставлен включённым."
    fi
}

step_create_user() {
    if [ -z "${USERNAME:-}" ]; then
        read -p "Введите имя нового sudo-пользователя: " USERNAME
        if [ -z "$USERNAME" ]; then
            echo "Имя пользователя не может быть пустым."
            exit 1
        fi
        save_var "USERNAME" "$USERNAME"
    else
        echo "Используем ранее сохранённое имя пользователя: $USERNAME"
    fi

    if id "$USERNAME" &>/dev/null; then
        echo "Пользователь $USERNAME уже существует, пропускаем useradd."
    else
        echo "Создаем пользователя $USERNAME..."
        useradd -m -s /bin/bash "$USERNAME"
    fi

    if [ ! -s "/etc/shadow" ] || ! passwd -S "$USERNAME" 2>/dev/null | grep -q " P "; then
        echo "Введите пароль для пользователя $USERNAME:"
        until passwd "$USERNAME"; do
            echo "Попробуйте ещё раз."
        done
    else
        echo "Пароль для $USERNAME уже установлен, пропускаем."
    fi

    usermod -aG sudo "$USERNAME"
    echo "Пользователь $USERNAME добавлен в группу sudo."
}

step_ssh_disable_root() {
    local SSHD="/etc/ssh/sshd_config"

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD"
    grep -q "^PermitRootLogin" "$SSHD" || echo "PermitRootLogin no" >> "$SSHD"

    for f in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] || continue
        if grep -q "PermitRootLogin" "$f"; then
            sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$f"
            echo "Root-доступ отключен в конфиге: $f"
        fi
    done
}

step_ssh_key() {
    local SSHD="/etc/ssh/sshd_config"

    if [ -z "${PUB_KEY_ENTERED:-}" ]; then
        read -p "Введите ваш публичный SSH-ключ (нажмите Enter, чтобы пропустить): " PUB_KEY
        save_var "PUB_KEY" "$PUB_KEY"
        save_var "PUB_KEY_ENTERED" "yes"
    else
        echo "Используем ранее введённый SSH-ключ (или его отсутствие)."
    fi

    if [ -n "${PUB_KEY:-}" ]; then
        local KEY_TYPE
        KEY_TYPE=$(echo "$PUB_KEY" | awk '{print $1}')
        case "$KEY_TYPE" in
            ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com)
                local SSH_DIR="/home/$USERNAME/.ssh"
                mkdir -p "$SSH_DIR"
                if ! grep -qxF "$PUB_KEY" "$SSH_DIR/authorized_keys" 2>/dev/null; then
                    echo "$PUB_KEY" >> "$SSH_DIR/authorized_keys"
                fi
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
}

step_ufw() {
    if [ -z "${RESTRICT_SSH:-}" ]; then
        read -p "Ограничить доступ к SSH (порт 22) только для вашего текущего IP? (y/n) [по умолчанию n]: " RESTRICT_SSH
        RESTRICT_SSH=${RESTRICT_SSH:-n}
        save_var "RESTRICT_SSH" "$RESTRICT_SSH"
    else
        echo "Используем ранее сохранённый ответ: RESTRICT_SSH=$RESTRICT_SSH"
    fi

    if [ "$RESTRICT_SSH" = "y" ]; then
        local CLIENT_IP
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

    local SERVER_IP
    SERVER_IP=$(hostname -I | tr ' ' '\n' | grep -Ev ':' | head -1)
    echo "IP сервера: $SERVER_IP"

    ufw insert 1 deny from "$SERVER_IP/22"
    ufw allow 443 comment "HTTPS"
    ufw allow 80 comment "HTTP - ACME challenge"

    if [ -z "${PANEL_IP:-}" ]; then
        read -p "Введите IP панели управления: " PANEL_IP
        until validate_ip "$PANEL_IP"; do
            read -p "Некорректный IP. Введите IP панели управления еще раз: " PANEL_IP
        done
        save_var "PANEL_IP" "$PANEL_IP"
    else
        echo "Используем ранее сохранённый IP панели: $PANEL_IP"
    fi

    if [ -z "${PANEL_PORT:-}" ]; then
        read -p "Введите порт панели управления [по умолчанию 2222]: " PANEL_PORT
        PANEL_PORT=${PANEL_PORT:-2222}
        until validate_port "$PANEL_PORT"; do
            read -p "Некорректный порт. Введите порт панели еще раз: " PANEL_PORT
        done
        save_var "PANEL_PORT" "$PANEL_PORT"
    else
        echo "Используем ранее сохранённый порт панели: $PANEL_PORT"
    fi

    ufw allow from "$PANEL_IP" to any port "$PANEL_PORT" proto tcp comment "Panel"

    ufw --force enable
    echo "UFW настроен и включён."
}

step_limits() {
    local LIMITS_CONF="/etc/security/limits.conf"

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

    if ! grep -q "DefaultLimitNOFILE" /etc/systemd/system.conf; then
        echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf
        systemctl daemon-reexec
    fi

    ulimit -n 1048576
}

step_selfsteal() {
    echo "Запуск скрипта Selfsteal..."
    bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install
}

step_remnanode() {
    if [ -z "${NODE_KEY_ENTERED:-}" ]; then
        read -p "Введите secret_key ноды из панели: " KEY
        read -p "Повторите secret_key: " KEY_CONFIRM

        if [ "$KEY" != "$KEY_CONFIRM" ] || [ -z "$KEY" ]; then
            echo "Ключи не совпадают или пусты. Установка remnanode прервана."
            exit 1
        fi
        save_var "KEY" "$KEY"
        save_var "NODE_KEY_ENTERED" "yes"
    else
        echo "Используем ранее сохранённый secret_key ноды."
    fi

    echo "Установка remnanode..."
    timeout 180s bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh) @ install \
        --force --secret-key="$KEY" --port="$PANEL_PORT" < /dev/null || true

    echo "Проверяем, что контейнер remnanode запущен..."
    local tries=0
    while [ "$tries" -lt 10 ]; do
        if docker ps --format '{{.Names}}' | grep -qi remnanode; then
            echo "✔️  Контейнер remnanode запущен."
            scrub_var "KEY"
            scrub_var "NODE_KEY_ENTERED"
            return 0
        fi
        tries=$((tries + 1))
        sleep 3
    done

    echo "❌ Не удалось подтвердить, что remnanode запущен. Проверьте вручную: docker ps -a"
    exit 1
}

step_warp() {
    echo "Установка Cloudflare WARP..."
    bash <(curl -sL https://github.com/DigneZzZ/remnawave-scripts/raw/main/wtm.sh) install-warp
}

step_ssl() {
    if [ -z "${SSL:-}" ]; then
        read -p "Вынести SSL сертификаты из контейнера и примонтировать к ноде? (y/n) [По умолчанию n]: " SSL
        SSL=${SSL:-n}
        save_var "SSL" "$SSL"
    else
        echo "Используем ранее сохранённый ответ: SSL=$SSL"
    fi

    if [ "$SSL" = "y" ]; then
        echo "Выполняется автоматическая настройка томов и путей..."

        local CADDY_COMPOSE="/opt/caddy/docker-compose.yml"
        if [ -f "$CADDY_COMPOSE" ]; then
            sed -i 's|caddy_data:data|./caddy_data:data|g' "$CADDY_COMPOSE"
            sed -i 's|caddy_data:/data|./caddy_data:/data|g' "$CADDY_COMPOSE"
            echo "Файл $CADDY_COMPOSE успешно обновлен."
            cd /opt/caddy && docker compose down && docker compose up -d
            cd - > /dev/null
        else
            echo "⚠️ Файл $CADDY_COMPOSE не найден. Пропускаем этот шаг."
        fi

        local NODE_COMPOSE="/opt/remnanode/docker-compose.yml"
        local CERT_HOST_PATH="/opt/caddy/caddy_data/caddy/certificates/acme-v02.api.letsencrypt.org-directory"

        if [ -f "$NODE_COMPOSE" ]; then
            if ! grep -q "acme-v02.api.letsencrypt.org" "$NODE_COMPOSE"; then
                cp "$NODE_COMPOSE" "$NODE_COMPOSE.bak"
                awk -v certpath="$CERT_HOST_PATH" '
                    BEGIN { done = 0 }
                    {
                        if (!done && $0 ~ /^[[:space:]]*#?[[:space:]]*volumes:[[:space:]]*$/) {
                            match($0, /^[[:space:]]*/)
                            indent = substr($0, RSTART, RLENGTH)
                            print indent "volumes:"
                            print indent "  - " certpath ":/etc/xray/certs:ro"
                            done = 1
                            next
                        }
                        print
                    }
                ' "$NODE_COMPOSE" > "$NODE_COMPOSE.tmp"

                if grep -q "$CERT_HOST_PATH" "$NODE_COMPOSE.tmp"; then
                    mv "$NODE_COMPOSE.tmp" "$NODE_COMPOSE"
                    echo "Файл $NODE_COMPOSE успешно обновлен."
                    cd /opt/remnanode && docker compose down && docker compose up -d
                    cd - > /dev/null
                else
                    rm -f "$NODE_COMPOSE.tmp"
                    echo "⚠️ Не найдена секция 'volumes:' (даже закомментированная) в $NODE_COMPOSE."
                    echo "   Добавьте вручную том: ${CERT_HOST_PATH}:/etc/xray/certs:ro"
                fi
            else
                echo "Сертификаты уже примонтированы в $NODE_COMPOSE."
            fi
        else
            echo "⚠️ Файл $NODE_COMPOSE не найден. Пропускаем этот шаг."
        fi
    fi
}

run_step "base_packages"     step_base_packages
run_step "bbr"                step_bbr
run_step "ipv6"               step_ipv6
run_step "create_user"        step_create_user
run_step "ssh_disable_root"   step_ssh_disable_root
run_step "ssh_key"            step_ssh_key
run_step "ufw"                step_ufw
run_step "limits"             step_limits
run_step "selfsteal"          step_selfsteal
run_step "remnanode"          step_remnanode
run_step "warp"               step_warp
run_step "ssl"                step_ssl

echo "🎉 Настройка сервера успешно завершена!"
exit 0
