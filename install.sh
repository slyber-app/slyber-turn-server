#!/usr/bin/env bash
set -euo pipefail

REPO="slyber-app/slyber-turn-server"
INSTALL_DIR="/opt/slyber_turn"
BIN_PATH="${INSTALL_DIR}/slyber_turn"
SYMLINK_PATH="/usr/local/bin/slyber_turn"
SERVICE_FILE="/etc/systemd/system/slyber_turn.service"
VERSION="${VERSION:-latest}"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERR] This script must be run as root (use sudo)." >&2
    exit 1
fi

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
if [ "${OS}" != "linux" ]; then
    echo "[ERR] Unsupported operating system: ${OS} (Linux is required)." >&2
    exit 1
fi

RAW_ARCH="$(uname -m)"
case "${RAW_ARCH}" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        echo "[ERR] Unsupported CPU architecture: ${RAW_ARCH}" >&2
        exit 1
        ;;
esac

BIN_FILENAME="slyber_turn-linux-${ARCH}"
echo "[INFO] Detected platform: linux/${ARCH}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if [ "${VERSION}" = "latest" ]; then
    RELEASE_BASE="https://github.com/${REPO}/releases/latest/download"
else
    RELEASE_BASE="https://github.com/${REPO}/releases/download/${VERSION}"
fi
RAW_FALLBACK_BASE="https://raw.githubusercontent.com/${REPO}/main/bin"

echo "[INFO] Downloading ${BIN_FILENAME}..."
if curl -fsSL "${RELEASE_BASE}/${BIN_FILENAME}" -o "${TMP_DIR}/${BIN_FILENAME}" 2>/dev/null; then
    DOWNLOAD_SOURCE="${RELEASE_BASE}"
elif curl -fsSL "${RAW_FALLBACK_BASE}/${BIN_FILENAME}" -o "${TMP_DIR}/${BIN_FILENAME}" 2>/dev/null; then
    DOWNLOAD_SOURCE="${RAW_FALLBACK_BASE}"
else
    echo "[ERR] Failed to download ${BIN_FILENAME} from ${REPO}." >&2
    exit 1
fi

if curl -fsSL "${DOWNLOAD_SOURCE}/SHA256SUMS" -o "${TMP_DIR}/SHA256SUMS" 2>/dev/null; then
    echo "[INFO] Verifying SHA256 checksum..."
    (
        cd "${TMP_DIR}"
        grep " ${BIN_FILENAME}\$" SHA256SUMS | sha256sum -c - >/dev/null
    )
    echo "[OK] Checksum verified"
fi

timedatectl set-ntp true 2>/dev/null || true

mkdir -p "${INSTALL_DIR}/certs"
chmod 755 "${INSTALL_DIR}"

install -m 0755 "${TMP_DIR}/${BIN_FILENAME}" "${BIN_PATH}"
ln -sf "${BIN_PATH}" "${SYMLINK_PATH}"
echo "[OK] Installed binary to ${BIN_PATH} (symlinked to ${SYMLINK_PATH})"

if [ ! -f "${INSTALL_DIR}/.env" ]; then
    GENERATED_SECRET="${TURN_SECRET:-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32)}"
    CONF_REALM="${REALM:-turn.local}"
    CONF_PUBLIC_IP="${PUBLIC_IP:-auto}"
    CONF_UDP_PORT="${UDP_PORT:-3478}"
    CONF_TCP_PORT="${TCP_PORT:-3478}"
    CONF_TLS_PORT="${TLS_PORT:-5349}"
    CONF_HTTP_PORT="${HTTP_PORT:-:8080}"
    CONF_MAX_KBPS="${MAX_KBPS_PER_SESSION:-0}"

    cat > "${INSTALL_DIR}/.env" <<EOF
PUBLIC_IP="${CONF_PUBLIC_IP}"
TURN_SECRET="${GENERATED_SECRET}"
REALM="${CONF_REALM}"
UDP_PORT=${CONF_UDP_PORT}
TCP_PORT=${CONF_TCP_PORT}
TLS_PORT=${CONF_TLS_PORT}
TLS_CERT_FILE=""
TLS_KEY_FILE=""
TLS_SELF_SIGNED=false
HTTP_ENABLED=true
HTTP_PORT="${CONF_HTTP_PORT}"
HTTP_TLS=false
REQUIRE_SECRET=false
RELAY_MIN_PORT=49152
RELAY_MAX_PORT=65535
ALLOWED_ORIGINS="*"
ALLOWED_IPS=""
CREDENTIAL_TTL_SEC=7200
MAX_KBPS_PER_SESSION=${CONF_MAX_KBPS}
DATA_DIR="${INSTALL_DIR}"
LOG_FORMAT="json"
EOF
    chmod 600 "${INSTALL_DIR}/.env"
    echo "[OK] Created initial configuration in ${INSTALL_DIR}/.env"
else
    echo "[INFO] Existing configuration found at ${INSTALL_DIR}/.env (preserved)"
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "[INFO] Applying UFW firewall rules..."
    ufw allow 3478/udp >/dev/null 2>&1 || true
    ufw allow 3478/tcp >/dev/null 2>&1 || true
    ufw allow 5349/tcp >/dev/null 2>&1 || true
    ufw allow 49152:65535/udp >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    echo "[INFO] Applying firewalld rules..."
    firewall-cmd --permanent --add-port=3478/udp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=3478/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=5349/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=49152-65535/udp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Slyber Turn Server (WebRTC TURN/STUN)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${BIN_PATH} server
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable slyber_turn >/dev/null 2>&1
systemctl restart slyber_turn
sleep 1

echo "[INFO] Running self-diagnostics..."
(cd "${INSTALL_DIR}" && "${BIN_PATH}" doctor) || true

CURRENT_SECRET="$(grep '^TURN_SECRET=' "${INSTALL_DIR}/.env" | cut -d= -f2- | tr -d '"')"
echo ""
echo "[OK] Slyber Turn Server is installed and running."
echo "  Service     : systemctl status slyber_turn"
echo "  Config file : ${INSTALL_DIR}/.env"
echo "  TURN Secret : ${CURRENT_SECRET}"
echo "  Diagnostics : sudo slyber_turn doctor"
echo "  Benchmark   : sudo slyber_turn bench -clients 20 -duration 5s"