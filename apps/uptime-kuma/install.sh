# Uptime Kuma Installer for VirtFusion
# This script is designed to run non-interactively within a Cloud-Init context.

set -e

# Repository Configuration (Rule 2 & 3)
REPO_URL="https://raw.githubusercontent.com/StreetHosting/installers/stable"

# Run in background using systemd-run for persistence
if [[ "$1" != "--background" ]]; then
    touch /var/log/strt_inst_uptime_kuma.log
    chmod 644 /var/log/strt_inst_uptime_kuma.log

    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - Relançando o instalador em segundo plano via systemd-run para não bloquear o boot..." >> /var/log/strt_inst_uptime_kuma.log

    INSTALLER_PATH="/tmp/strt_inst_uptime_kuma_exec.sh"
    if [ -f "$0" ] && [[ "$0" == *.sh ]]; then
        cat "$0" > "$INSTALLER_PATH"
    else
        curl -fsSL "$REPO_URL/apps/uptime-kuma/install.sh" | sed 's/\r$//' > "$INSTALLER_PATH"
    fi
    chmod +x "$INSTALLER_PATH"

    systemd-run --unit=strt-inst-uptime-kuma --on-active=1 --timer-property=AccuracySec=1s /bin/bash -c "$INSTALLER_PATH --background &>> /var/log/strt_inst_uptime_kuma.log"
    exit 0
fi

# Network Initialization (Rule 9)
sleep 15

# Ensure log file exists
touch /var/log/strt_inst_uptime_kuma.log
chmod 644 /var/log/strt_inst_uptime_kuma.log

# Download Shared Utilities
curl -fsSL "$REPO_URL/shared/logging.sh?nocache=1" | sed 's/\r$//' > /tmp/logging.sh
curl -fsSL "$REPO_URL/shared/docker.sh?nocache=1" | sed 's/\r$//' > /tmp/docker.sh
curl -fsSL "$REPO_URL/shared/motd.sh?nocache=1" | sed 's/\r$//' > /tmp/motd.sh
curl -fsSL "$REPO_URL/shared/domain-wizard.sh?nocache=1" | sed 's/\r$//' > /tmp/domain-wizard.sh

# Source Utilities
source /tmp/logging.sh
source /tmp/docker.sh
source /tmp/motd.sh
source /tmp/domain-wizard.sh

# MOTD Setup (early - atualiza status durante a instalação)
motd_setup "uptime-kuma"

log_info "Iniciando o processo de instalação do Uptime Kuma..."

# OS Detection & Validation (Rule 4)
if [ -f /etc/os-release ]; then
    source /etc/os-release
    log_info "SO Detectado: $NAME $VERSION_ID"
else
    log_error "Não foi possível detectar o sistema operacional."
    exit 1
fi

# Ensure APT-based system (Rule 4)
if ! command -v apt-get >/dev/null 2>&1; then
    log_error "Este instalador suporta apenas sistemas baseados em APT (Ubuntu/Debian)."
    exit 1
fi

# Install Docker (Rule 6 & 7)
install_docker

# Application Isolation & Data Persistence (Rule 27 & 31)
APP_DIR="/opt/apps/uptime-kuma"
log_info "Configurando o diretório da aplicação: $APP_DIR"
mkdir -p "$APP_DIR/data"

cd "$APP_DIR"

# Get Public IP for configuration
SERVER_IP=$(curl -s https://ifconfig.me || echo "SERVER_IP")

# Deploy Uptime Kuma using Docker Compose (Rule 6)
log_info "Gerando a configuração do Docker Compose..."
cat <<EOF > docker-compose.yml
services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: always
    volumes:
      - ./data:/app/data
    ports:
      - "127.0.0.1:3001:3001"
EOF

# Start the application (Rule 23)
log_info "Iniciando o container do Uptime Kuma..."
docker compose up -d

# Wait for container to be running
log_info "Aguardando o Uptime Kuma iniciar..."
MAX_RETRIES=10
COUNT=0
until [ "$(docker inspect --format='{{.State.Running}}' uptime-kuma 2>/dev/null)" == "true" ] || [ $COUNT -eq $MAX_RETRIES ]; do
    sleep 5
    COUNT=$((COUNT + 1))
    log_info "Aguardando... ($COUNT/$MAX_RETRIES)"
done

if [ "$(docker inspect --format='{{.State.Running}}' uptime-kuma 2>/dev/null)" != "true" ]; then
    log_error "O container Uptime Kuma falhou ao iniciar."
    docker logs uptime-kuma --tail 20
    exit 1
fi

log_success "O Uptime Kuma foi instalado e iniciado com sucesso."

# Setup Nginx Reverse Proxy
install_nginx_proxy "uptime-kuma" "$SERVER_IP" "3001"

# Install Domain Wizard (no post-hook needed — Uptime Kuma has no app-level URL config)
install_domain_wizard "uptime-kuma" "Uptime Kuma" "/var/log/strt_inst_uptime_kuma.log"

# Save Credentials
CRED_DIR="/etc/street_preinstallers/credentials"
mkdir -p "$CRED_DIR"
cat <<EOF > "$CRED_DIR/uptime-kuma.txt"
====================================================
Uptime Kuma - Informações de Acesso
Gerado em: $(date)
====================================================

Acesso: http://${SERVER_IP}
Porta: 80 (Nginx) → 3001 (Uptime Kuma)

Nota: Configure seu usuário administrador no primeiro acesso.

Diretório da Aplicação: ${APP_DIR}
====================================================
EOF
chmod 600 "$CRED_DIR/uptime-kuma.txt"

# Final Access Information (Rule 10)
log_success "Instalação do Uptime Kuma concluída!"
log_success "Acesso: http://${SERVER_IP}"
log_success "Porta: 80 (Nginx → 3001)"
log_success "Credenciais salvas em: $CRED_DIR/uptime-kuma.txt"
