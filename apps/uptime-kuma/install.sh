# Uptime Kuma Installer for VirtFusion
# This script is designed to run non-interactively within a Cloud-Init context.

set -e

# Network Initialization (Rule 9)
# Assume the network may not be fully ready at boot.
sleep 15

# Repository Configuration (Rule 2 & 3)
# Always reference the stable branch for production installers.
REPO_URL="https://raw.githubusercontent.com/StreetHosting/installers/stable"

# Download Shared Utilities (Rule 21 & 28)
# Download Shared Utilities
curl -fsSL "$REPO_URL/shared/logging.sh?nocache=1" | sed 's/\r$//' > /tmp/logging.sh
curl -fsSL "$REPO_URL/shared/docker.sh?nocache=1" | sed 's/\r$//' > /tmp/docker.sh

# Source Utilities
source /tmp/logging.sh
source /tmp/docker.sh

# Run in background using systemd-run for persistence
if [[ "$1" != "--background" ]]; then
    log_info "Relançando o instalador em segundo plano via systemd-run para não bloquear o boot..."
    
    # Save the script to a physical file if it was piped or is not in a stable location
    INSTALLER_PATH="/tmp/strt_inst_uptime_kuma_exec.sh"
    cat "$0" > "$INSTALLER_PATH"
    chmod +x "$INSTALLER_PATH"
    
    # The command is wrapped in 'bash -c "..."' to handle the output redirection correctly
    systemd-run --unit=strt-inst-uptime-kuma --on-active=3 --timer-property=AccuracySec=1s /bin/bash -c "$INSTALLER_PATH --background &>> /var/log/strt_inst_uptime_kuma.log"
    exit 0
fi

log_info "Executando em segundo plano. Logs disponíveis em /var/log/strt_inst_uptime_kuma.log"

# Ensure log file exists
touch /var/log/strt_inst_uptime_kuma.log
chmod 644 /var/log/strt_inst_uptime_kuma.log

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
# This utility handles idempotency and non-interactive installation.
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
      - "3001:3001"
EOF

# Start the application (Rule 23)
log_info "Iniciando o container do Uptime Kuma..."
docker compose up -d

# Save Credentials
CRED_DIR="/etc/street_preinstallers/credentials"
mkdir -p "$CRED_DIR"
cat <<EOF > "$CRED_DIR/uptime-kuma.txt"
====================================================
Uptime Kuma - Informações de Acesso
Gerado em: $(date)
====================================================

Acesso: http://${SERVER_IP}:3001
Porta: 3001

Nota: Configure seu usuário administrador no primeiro acesso.
====================================================
EOF
chmod 600 "$CRED_DIR/uptime-kuma.txt"

# Final Access Information (Rule 10)
log_success "Instalação do Uptime Kuma concluída!"
log_info "Acesso: http://${SERVER_IP}:3001"
log_info "Porta: 3001"
