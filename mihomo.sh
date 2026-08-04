#!/usr/bin/env bash

set -euo pipefail

REPO="MetaCubeX/mihomo"
INSTALL_DIR="/usr/local/bin"
BIN_NAME="mihomo"
CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
CRON_COMMENT="# mihomo-subscription-update"
USER_AGENT="chlenix"

MIRRORS=(
    ""
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
    "https://mirror.ghproxy.com/"
)

CURL_OPTS=(--connect-timeout 8 --max-time 30 --retry 1 --retry-delay 1)

if [[ "${EUID}" -ne 0 ]]; then
    echo "Ошибка: скрипт нужно запускать от root (используйте sudo)." >&2
    exit 1
fi

PKG_MANAGER=""
if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
elif command -v pacman &>/dev/null; then
    PKG_MANAGER="pacman"
elif command -v zypper &>/dev/null; then
    PKG_MANAGER="zypper"
elif command -v apk &>/dev/null; then
    PKG_MANAGER="apk"
fi

pkg_name_for() {
    local cmd="$1"
    case "${cmd}" in
        crontab)
            case "${PKG_MANAGER}" in
                apt)    echo "cron" ;;
                dnf|yum) echo "cronie" ;;
                pacman) echo "cronie" ;;
                zypper) echo "cronie" ;;
                apk)    echo "cronie" ;;
            esac
            ;;
        *)
            echo "${cmd}"
            ;;
    esac
}

install_pkg() {
    local pkg="$1"
    echo "==> Устанавливаю пакет '${pkg}' (${PKG_MANAGER})..."
    case "${PKG_MANAGER}" in
        apt)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}"
            ;;
        dnf)
            dnf install -y "${pkg}"
            ;;
        yum)
            yum install -y "${pkg}"
            ;;
        pacman)
            pacman -Sy --noconfirm "${pkg}"
            ;;
        zypper)
            zypper install -y "${pkg}"
            ;;
        apk)
            apk add --no-cache "${pkg}"
            ;;
        *)
            echo "Ошибка: не удалось определить пакетный менеджер, установите '${pkg}' вручную." >&2
            exit 1
            ;;
    esac
}

if ! command -v systemctl &>/dev/null; then
    echo "Ошибка: не найден systemctl. В этой системе не используется systemd, автоматическая установка невозможна." >&2
    exit 1
fi

for cmd in curl gzip install crontab; do
    if ! command -v "${cmd}" &>/dev/null; then
        pkg="$(pkg_name_for "${cmd}")"
        if [[ -z "${pkg}" || -z "${PKG_MANAGER}" ]]; then
            echo "Ошибка: не найдена утилита '${cmd}', и не удалось определить, каким пакетом её поставить." >&2
            echo "Установите её вручную и запустите скрипт снова." >&2
            exit 1
        fi
        install_pkg "${pkg}"
    fi
done

if command -v crontab &>/dev/null; then
    for svc in cron crond cronie; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1 \
            && systemctl list-unit-files "${svc}.service" | grep -q "${svc}.service"; then
            systemctl enable --now "${svc}" &>/dev/null || true
            break
        fi
    done
fi

for cmd in curl gzip install systemctl crontab; do
    if ! command -v "${cmd}" &>/dev/null; then
        echo "Ошибка: не удалось установить '${cmd}' автоматически. Установите вручную." >&2
        exit 1
    fi
done

ARCH_RAW="$(uname -m)"
case "${ARCH_RAW}" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    armv7l|armv7)
        ARCH="armv7"
        ;;
    armv6l)
        ARCH="armv6"
        ;;
    i386|i686)
        ARCH="386"
        ;;
    *)
        echo "Ошибка: неподдерживаемая архитектура '${ARCH_RAW}'." >&2
        exit 1
        ;;
esac

echo "==> Обнаружена архитектура: ${ARCH_RAW} -> ${ARCH}"

AMD64_LEVEL=""
if [[ "${ARCH}" == "amd64" ]]; then
    has_flag() { grep -qw "$1" /proc/cpuinfo 2>/dev/null; }

    if has_flag avx2 && has_flag bmi1 && has_flag bmi2 && has_flag fma && has_flag movbe; then
        AMD64_LEVEL="v3"
    elif has_flag sse4_2 && has_flag popcnt; then
        AMD64_LEVEL="v2"
    else
        AMD64_LEVEL="v1"
    fi
    echo "==> Поддерживаемый уровень микроархитектуры CPU: x86-64-${AMD64_LEVEL}"
fi

WORKING_MIRROR=""
fetch_release_json() {
    local real_url="$1"
    local mirror label http_code tmp_file

    tmp_file="$(mktemp)"

    for mirror in "${MIRRORS[@]}"; do
        label="${mirror:-(прямое подключение)}"
        echo "==> Пробую ${label} ..." >&2

        http_code="$(curl -sSL "${CURL_OPTS[@]}" \
            -H "Accept: application/vnd.github+json" \
            -w "%{http_code}" \
            -o "${tmp_file}" \
            "${mirror}${real_url}" 2>/dev/null || echo "000")"

        if [[ "${http_code}" == "200" ]] && grep -q '"tag_name"' "${tmp_file}" 2>/dev/null; then
            WORKING_MIRROR="${mirror}"
            echo "==> Успешно через ${label} (HTTP ${http_code})" >&2
            cat "${tmp_file}"
            rm -f "${tmp_file}"
            return 0
        fi

        if [[ "${http_code}" == "200" ]]; then
            echo "    HTTP 200, но это не похоже на релиз GitHub (нет tag_name)." >&2
        else
            echo "    Не удалось (HTTP ${http_code:-нет ответа})." >&2
        fi
        echo "    Начало ответа: $(head -c 150 "${tmp_file}" 2>/dev/null | tr -d '\n\r')" >&2

        if grep -q '"message"' "${tmp_file}" 2>/dev/null; then
            ERR_MSG="$(grep -o '"message":[[:space:]]*"[^"]*"' "${tmp_file}" | head -n1 || true)"
            echo "    Ответ GitHub API: ${ERR_MSG:-см. выше}" >&2
        fi
    done

    rm -f "${tmp_file}"
    return 1
}

echo "==> Запрашиваю информацию о последнем релизе ${REPO}..."

if ! RELEASE_JSON="$(fetch_release_json "https://api.github.com/repos/${REPO}/releases/latest")"; then
    echo "Ошибка: не удалось получить корректные данные о релизе ни напрямую, ни через зеркала." >&2
    echo "Похоже, api.github.com недоступен или подменяется в вашей сети (см. 'Начало ответа' выше)." >&2
    echo "Возможные причины: блокировка провайдером/DPI, отсутствие интернета, исчерпан rate limit GitHub API (60 запросов/час без токена)." >&2
    echo "Ручная проверка: curl -v https://api.github.com/repos/${REPO}/releases/latest" >&2
    exit 1
fi

TAG_NAME="$( (echo "${RELEASE_JSON}" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/') || true )"

if [[ -z "${TAG_NAME}" ]]; then
    echo "Ошибка: не удалось определить тег последнего релиза (неожиданный формат ответа)." >&2
    exit 1
fi

echo "==> Последний релиз: ${TAG_NAME}"

if [[ "${ARCH}" == "amd64" ]]; then
    ASSET_NAME_PATTERN="mihomo-linux-amd64-${AMD64_LEVEL}-${TAG_NAME}.gz"
else
    ASSET_NAME_PATTERN="mihomo-linux-${ARCH}-${TAG_NAME}.gz"
fi

DOWNLOAD_URL="$( (echo "${RELEASE_JSON}" \
    | grep -o "\"browser_download_url\":[[:space:]]*\"[^\"]*${ASSET_NAME_PATTERN}\"" \
    | head -n1 \
    | sed -E 's/.*"(https:[^"]+)"/\1/') || true )"

if [[ -z "${DOWNLOAD_URL}" ]]; then
    echo "Ошибка: не удалось найти файл релиза для маски '${ASSET_NAME_PATTERN}'." >&2
    echo "Проверьте вручную страницу релизов: https://github.com/${REPO}/releases" >&2
    exit 1
fi

echo "==> Файл для загрузки: ${DOWNLOAD_URL}"

fetch_via_mirrors() {
    local real_url="$1"
    local out_file="$2"
    local mirror label http_code size

    for mirror in "${MIRRORS[@]}"; do
        label="${mirror:-(прямое подключение)}"
        echo "==> Пробую ${label} ..." >&2

        http_code="$(curl -sSL "${CURL_OPTS[@]}" \
            -w "%{http_code}" \
            -o "${out_file}" \
            "${mirror}${real_url}" 2>/dev/null || echo "000")"

        size="$(stat -c%s "${out_file}" 2>/dev/null || echo 0)"

        if [[ "${http_code}" == "200" && "${size}" -gt 1000000 ]]; then
            echo "==> Успешно через ${label} (HTTP ${http_code}, ${size} байт)" >&2
            return 0
        else
            echo "    Не удалось (HTTP ${http_code:-нет ответа}, размер ${size} байт)." >&2
        fi
    done

    return 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

TMP_GZ="${TMP_DIR}/${BIN_NAME}.gz"
TMP_BIN="${TMP_DIR}/${BIN_NAME}"

echo "==> Скачиваю бинарник..."
DOWNLOAD_MIRRORS=("${MIRRORS[@]}")
if [[ -n "${WORKING_MIRROR}" ]]; then
    DOWNLOAD_MIRRORS=("${WORKING_MIRROR}" "${MIRRORS[@]}")
fi
MIRRORS=("${DOWNLOAD_MIRRORS[@]}")

if ! fetch_via_mirrors "${DOWNLOAD_URL}" "${TMP_GZ}"; then
    echo "Ошибка: не удалось скачать бинарник mihomo ни напрямую, ни через зеркала." >&2
    exit 1
fi

echo "==> Распаковываю..."
gzip -d -c "${TMP_GZ}" > "${TMP_BIN}"
chmod +x "${TMP_BIN}"

echo "==> Устанавливаю в ${INSTALL_DIR}/${BIN_NAME}..."
install -m 755 "${TMP_BIN}" "${INSTALL_DIR}/${BIN_NAME}"

INSTALLED_VERSION="$("${INSTALL_DIR}/${BIN_NAME}" -v 2>/dev/null || true)"
echo "==> Установлено: ${INSTALLED_VERSION:-${TAG_NAME}}"

mkdir -p "${CONFIG_DIR}"

SUBSCRIPTION_URL=""
while [[ -z "${SUBSCRIPTION_URL}" ]]; do
    read -r -p "Введите ссылку на подписку (URL конфига): " SUBSCRIPTION_URL
    if [[ -z "${SUBSCRIPTION_URL}" ]]; then
        echo "Ссылка не может быть пустой, попробуйте снова."
    fi
done

echo "==> Скачиваю конфиг по подписке в ${CONFIG_FILE}..."
if ! curl -s -L -A "${USER_AGENT}" "${SUBSCRIPTION_URL}" -o "${CONFIG_FILE}"; then
    echo "Предупреждение: не удалось скачать конфиг сейчас. Cron-задача попробует позже." >&2
fi

echo "==> Создаю systemd-юнит ${SERVICE_FILE}..."
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=mihomo daemon
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${BIN_NAME} -d ${CONFIG_DIR}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mihomo
systemctl restart mihomo || echo "Предупреждение: mihomo не запустился, проверьте конфиг." >&2

# ---------- Cron-задача ----------
CRON_LINE="0 4 * * * curl -s -L -A \"${USER_AGENT}\" \"${SUBSCRIPTION_URL}\" -o ${CONFIG_FILE} && sleep 3 && systemctl restart mihomo ${CRON_COMMENT}"

echo "==> Настраиваю cron-задачу обновления подписки..."

if { { crontab -l 2>/dev/null || true; } | grep -v "${CRON_COMMENT}" || true; echo "${CRON_LINE}"; } | crontab -; then
    echo "==> Cron-задача успешно установлена."
else
    echo "Предупреждение: не удалось автоматически прописать crontab." >&2
    echo "Добавьте вручную командой 'crontab -e' следующую строку:" >&2
    echo "  ${CRON_LINE}" >&2
fi

echo
echo "==================================================="
echo " Готово!"
echo " mihomo версии: ${INSTALLED_VERSION:-${TAG_NAME}}"
echo " Конфиг: ${CONFIG_FILE}"
echo " Cron-задача (обновление в 04:00 каждый день):"
echo "   ${CRON_LINE}"
echo " Статус сервиса: systemctl status mihomo"
echo "==================================================="
