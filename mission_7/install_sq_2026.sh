#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# SonarQube Community Build installer for Debian 13
# ============================================================

SONAR_VERSION="26.3.0.120487"
SONAR_DIR="/opt/sonarqube"
SONAR_DATA="/var/lib/sonarqube"
SONAR_USER="sonarqube"

SONAR_DB="sonarqube"
SONAR_DB_USER="sonarqube"
SONAR_DB_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"

SONAR_ZIP="sonarqube-${SONAR_VERSION}.zip"
SONAR_URL="https://binaries.sonarsource.com/Distribution/sonarqube/${SONAR_ZIP}"

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    echo "Example: sudo bash install-sonarqube.sh"
    exit 1
fi

# ------------------------------------------------------------
# OS check
# ------------------------------------------------------------

if [[ ! -f /etc/debian_version ]]; then
    echo "ERROR: This script is intended for Debian."
    exit 1
fi

echo
echo "============================================================"
echo " Installing SonarQube Community Build ${SONAR_VERSION}"
echo "============================================================"
echo

# ------------------------------------------------------------
# Install packages
# ------------------------------------------------------------

echo "[1/10] Installing required packages..."

apt-get update

apt-get install -y \
    openjdk-21-jdk \
    postgresql \
    postgresql-contrib \
    unzip \
    wget \
    curl \
    ca-certificates \
    openssl \
    procps \
    ufw

# ------------------------------------------------------------
# Java
# ------------------------------------------------------------

echo "[2/10] Checking Java..."

java -version

JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"

echo "JAVA_HOME=${JAVA_HOME}"

# ------------------------------------------------------------
# PostgreSQL
# ------------------------------------------------------------

echo "[3/10] Configuring PostgreSQL..."

systemctl enable --now postgresql

sudo -u postgres psql <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT FROM pg_catalog.pg_roles
        WHERE rolname = '${SONAR_DB_USER}'
    ) THEN
        CREATE ROLE ${SONAR_DB_USER}
        LOGIN
        PASSWORD '${SONAR_DB_PASSWORD}';
    ELSE
        ALTER ROLE ${SONAR_DB_USER}
        WITH LOGIN PASSWORD '${SONAR_DB_PASSWORD}';
    END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${SONAR_DB} OWNER ${SONAR_DB_USER}'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = '${SONAR_DB}'
)\gexec
EOF

# Ensure database ownership
sudo -u postgres psql -c \
    "ALTER DATABASE ${SONAR_DB} OWNER TO ${SONAR_DB_USER};"

# ------------------------------------------------------------
# SonarQube user
# ------------------------------------------------------------

echo "[4/10] Creating SonarQube system user..."

if ! id "${SONAR_USER}" >/dev/null 2>&1; then
    useradd \
        --system \
        --home-dir "${SONAR_DIR}" \
        --shell /usr/sbin/nologin \
        "${SONAR_USER}"
fi

# ------------------------------------------------------------
# Download SonarQube
# ------------------------------------------------------------

echo "[5/10] Downloading SonarQube ${SONAR_VERSION}..."

cd /tmp

rm -f "${SONAR_ZIP}"

wget -q --show-progress \
    "${SONAR_URL}" \
    -O "${SONAR_ZIP}"

if [[ ! -f "${SONAR_ZIP}" ]]; then
    echo "ERROR: SonarQube download failed."
    exit 1
fi

# ------------------------------------------------------------
# Install SonarQube
# ------------------------------------------------------------

echo "[6/10] Installing SonarQube..."

rm -rf "${SONAR_DIR}"

unzip -q "${SONAR_ZIP}" -d /opt

mv "/opt/sonarqube-${SONAR_VERSION}" "${SONAR_DIR}"

# ------------------------------------------------------------
# Data directories
# ------------------------------------------------------------

echo "[7/10] Creating SonarQube directories..."

mkdir -p \
    "${SONAR_DATA}/data" \
    "${SONAR_DATA}/temp" \
    "${SONAR_DATA}/logs"

chown -R "${SONAR_USER}:${SONAR_USER}" "${SONAR_DIR}"
chown -R "${SONAR_USER}:${SONAR_USER}" "${SONAR_DATA}"

chmod 750 "${SONAR_DIR}"
chmod 750 "${SONAR_DATA}"

# ------------------------------------------------------------
# SonarQube configuration
# ------------------------------------------------------------

echo "[8/10] Configuring SonarQube..."

SONAR_PROPERTIES="${SONAR_DIR}/conf/sonar.properties"

cat >> "${SONAR_PROPERTIES}" <<EOF

# ============================================================
# PostgreSQL
# ============================================================

sonar.jdbc.username=${SONAR_DB_USER}
sonar.jdbc.password=${SONAR_DB_PASSWORD}
sonar.jdbc.url=jdbc:postgresql://localhost:5432/${SONAR_DB}

# ============================================================
# Storage
# ============================================================

sonar.path.data=${SONAR_DATA}/data
sonar.path.temp=${SONAR_DATA}/temp

# ============================================================
# Web server
# ============================================================

sonar.web.host=0.0.0.0
sonar.web.port=9000

EOF

chown "${SONAR_USER}:${SONAR_USER}" "${SONAR_PROPERTIES}"

# ------------------------------------------------------------
# Elasticsearch/Linux limits
# ------------------------------------------------------------

echo "[9/10] Configuring Linux limits..."

cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF

sysctl --system

cat > /etc/security/limits.d/99-sonarqube.conf <<EOF
${SONAR_USER}   -   nofile   131072
${SONAR_USER}   -   nproc    8192
EOF

# ------------------------------------------------------------
# systemd service
# ------------------------------------------------------------

echo "[10/10] Creating systemd service..."

cat > /etc/systemd/system/sonarqube.service <<EOF
[Unit]
Description=SonarQube Community Build
Documentation=https://docs.sonarsource.com/sonarqube-community-build/
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=forking

User=${SONAR_USER}
Group=${SONAR_USER}

WorkingDirectory=${SONAR_DIR}

Environment="JAVA_HOME=${JAVA_HOME}"
Environment="SONAR_JAVA_PATH=${JAVA_HOME}/bin/java"

ExecStart=${SONAR_DIR}/bin/linux-x86-64/sonar.sh start
ExecStop=${SONAR_DIR}/bin/linux-x86-64/sonar.sh stop

Restart=always
RestartSec=10

LimitNOFILE=131072
LimitNPROC=8192

TimeoutStartSec=5min
TimeoutStopSec=5min

SuccessExitStatus=0 143

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable sonarqube
systemctl start sonarqube

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------

echo
echo "Configuring firewall..."

ufw allow 22/tcp
ufw allow 9000/tcp

# Enable UFW only if it isn't already active
if ! ufw status | grep -q "Status: active"; then
    ufw --force enable
fi

# ------------------------------------------------------------
# Wait for SonarQube
# ------------------------------------------------------------

echo
echo "Waiting for SonarQube to start..."

for i in {1..60}; do

    if curl -fsS http://127.0.0.1:9000/api/system/status >/dev/null 2>&1; then
        break
    fi

    sleep 5

done

# ------------------------------------------------------------
# Output
# ------------------------------------------------------------

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo
echo "============================================================"
echo " SonarQube installation complete"
echo "============================================================"
echo
echo "URL:"
echo "  http://${SERVER_IP}:9000"
echo
echo "Default login:"
echo "  Username: admin"
echo "  Password: admin"
echo
echo "PostgreSQL:"
echo "  Database: ${SONAR_DB}"
echo "  User:     ${SONAR_DB_USER}"
echo "  Password: ${SONAR_DB_PASSWORD}"
echo
echo "Installation:"
echo "  ${SONAR_DIR}"
echo
echo "Data:"
echo "  ${SONAR_DATA}"
echo
echo "Useful commands:"
echo "  systemctl status sonarqube"
echo "  systemctl restart sonarqube"
echo "  systemctl stop sonarqube"
echo "  journalctl -u sonarqube -f"
echo
echo "SonarQube logs:"
echo "  ${SONAR_DIR}/logs/"
echo
echo "============================================================"
