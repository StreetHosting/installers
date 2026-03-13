# n8n Installer for VirtFusion
# This script is designed to run non-interactively within a Cloud-Init context.

set -e

# Repository Configuration (Rule 2 & 3)
REPO_URL="https://raw.githubusercontent.com/StreetHosting/installers/stable"

# Run in background using systemd-run for persistence
if [[ "$1" != "--background" ]]; then
    touch /var/log/strt_inst_n8n.log
    chmod 644 /var/log/strt_inst_n8n.log

    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - Relançando o instalador em segundo plano via systemd-run para não bloquear o boot..." >> /var/log/strt_inst_n8n.log

    INSTALLER_PATH="/tmp/strt_inst_n8n_exec.sh"
    if [ -f "$0" ] && [[ "$0" == *.sh ]]; then
        cat "$0" > "$INSTALLER_PATH"
    else
        curl -fsSL "$REPO_URL/apps/n8n/install.sh" | sed 's/\r$//' > "$INSTALLER_PATH"
    fi
    chmod +x "$INSTALLER_PATH"

    systemd-run --unit=strt-inst-n8n --on-active=1 --timer-property=AccuracySec=1s /bin/bash -c "$INSTALLER_PATH --background &>> /var/log/strt_inst_n8n.log"
    exit 0
fi

# Network Initialization (Rule 9)
sleep 15

# Ensure log file exists
touch /var/log/strt_inst_n8n.log
chmod 644 /var/log/strt_inst_n8n.log

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
motd_setup "n8n"

log_info "Iniciando o processo de instalação do n8n..."

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
APP_DIR="/opt/apps/n8n"
log_info "Configurando o diretório da aplicação: $APP_DIR"
mkdir -p "$APP_DIR/n8n_data"
mkdir -p "$APP_DIR/postgres_data"

chown -R 1000:1000 "$APP_DIR/n8n_data"
cd "$APP_DIR"

# Get Public IP for configuration
SERVER_IP=$(curl -s https://ifconfig.me || echo "SERVER_IP")

# Generate Secure Auth Tokens and Passwords (Rule 5)
RUNNERS_AUTH_TOKEN=$(openssl rand -hex 16)
POSTGRES_ADMIN_PASS=$(openssl rand -hex 12)
POSTGRES_USER_PASS=$(openssl rand -hex 12)

# Create Postgres Init Script
log_info "Criando script de inicialização do Postgres..."
cat <<'INITEOF' > init-data.sh
#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE USER $POSTGRES_NON_ROOT_USER WITH PASSWORD '$POSTGRES_NON_ROOT_PASSWORD';
	GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_NON_ROOT_USER;
	GRANT ALL ON SCHEMA public TO $POSTGRES_NON_ROOT_USER;
EOSQL
INITEOF
chmod +x init-data.sh

# Create .env file for Docker Compose variable interpolation
log_info "Gerando arquivo de variáveis de ambiente..."
cat <<EOF > .env
POSTGRES_ADMIN_PASS=${POSTGRES_ADMIN_PASS}
POSTGRES_USER_PASS=${POSTGRES_USER_PASS}
RUNNERS_AUTH_TOKEN=${RUNNERS_AUTH_TOKEN}
WEBHOOK_URL=http://${SERVER_IP}/
N8N_PROTOCOL=http
N8N_EDITOR_BASE_URL=http://${SERVER_IP}/
EOF

# Deploy n8n Stack using Docker Compose (Rule 6)
log_info "Gerando a configuração do Docker Compose..."
cat <<'COMPOSEEOF' > docker-compose.yml
services:
  postgres:
    image: postgres:16
    container_name: n8n-postgres
    restart: always
    environment:
      - POSTGRES_USER=n8n_admin
      - POSTGRES_PASSWORD=${POSTGRES_ADMIN_PASS}
      - POSTGRES_DB=n8n_database
      - POSTGRES_NON_ROOT_USER=n8n_user
      - POSTGRES_NON_ROOT_PASSWORD=${POSTGRES_USER_PASS}
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
      - ./init-data.sh:/docker-entrypoint-initdb.d/init-data.sh
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h localhost -U n8n_admin -d n8n_database"]
      interval: 5s
      timeout: 5s
      retries: 10

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: always
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n_database
      - DB_POSTGRESDB_USER=n8n_user
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_USER_PASS}
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - NODE_ENV=production
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_EDITOR_BASE_URL=${N8N_EDITOR_BASE_URL}
      - N8N_SECURE_COOKIE=false
      - N8N_RUNNERS_ENABLED=true
      - N8N_RUNNERS_MODE=external
      - N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0
      - N8N_RUNNERS_AUTH_TOKEN=${RUNNERS_AUTH_TOKEN}
    ports:
      - "127.0.0.1:5678:5678"
    volumes:
      - ./n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678/healthz"]
      interval: 15s
      timeout: 10s
      retries: 15

  task-runners:
    image: n8nio/runners:latest
    container_name: n8n-runners
    restart: always
    environment:
      - N8N_RUNNERS_TASK_BROKER_URI=http://n8n:5679
      - N8N_RUNNERS_AUTH_TOKEN=${RUNNERS_AUTH_TOKEN}
    depends_on:
      - n8n
COMPOSEEOF

# Start Application (Rule 23)
log_info "Iniciando os containers do n8n..."
if ! docker compose up -d; then
    log_error "O Docker Compose falhou ao iniciar a stack."
    exit 1
fi

# Wait for healthy status
log_info "Aguardando o n8n ficar saudável..."
MAX_RETRIES=12
COUNT=0
until [ "$(docker inspect --format='{{.State.Health.Status}}' n8n 2>/dev/null)" == "healthy" ] || [ $COUNT -eq $MAX_RETRIES ]; do
    sleep 10
    COUNT=$((COUNT + 1))
    log_info "Aguardando... ($COUNT/$MAX_RETRIES)"
done

if [ "$(docker inspect --format='{{.State.Health.Status}}' n8n 2>/dev/null)" != "healthy" ]; then
    log_error "O container n8n falhou ao iniciar ou não está saudável."
    docker logs n8n --tail 20
    exit 1
fi

log_success "A stack n8n foi instalada e iniciada com sucesso."

# Setup Nginx Reverse Proxy
install_nginx_proxy "n8n" "$SERVER_IP" "5678"

# Create domain wizard post-hook (updates n8n env vars on domain change)
mkdir -p /etc/street_preinstallers
cat <<'HOOKEOF' > /etc/street_preinstallers/domain-hook.sh
#!/bin/bash
cd /opt/apps/n8n

NEW_PROTO="http"
if echo "$NEW_URL" | grep -q '^https'; then
    NEW_PROTO="https"
fi

sed -i "s|^WEBHOOK_URL=.*|WEBHOOK_URL=${NEW_URL}/|" .env
sed -i "s|^N8N_PROTOCOL=.*|N8N_PROTOCOL=${NEW_PROTO}|" .env
sed -i "s|^N8N_EDITOR_BASE_URL=.*|N8N_EDITOR_BASE_URL=${NEW_URL}/|" .env

docker compose up -d
HOOKEOF
chmod +x /etc/street_preinstallers/domain-hook.sh

# Install Domain Wizard
install_domain_wizard "n8n" "n8n" "/var/log/strt_inst_n8n.log"

# Save Credentials
CRED_DIR="/etc/street_preinstallers/credentials"
mkdir -p "$CRED_DIR"
cat <<EOF > "$CRED_DIR/n8n.txt"
====================================================
n8n - Credenciais de Acesso
Gerado em: $(date)
====================================================

Acesso: http://${SERVER_IP}
Porta: 80 (Nginx) → 5678 (n8n)

Banco de Dados (PostgreSQL):
Database: n8n_database
Admin User: n8n_admin
Admin Pass: ${POSTGRES_ADMIN_PASS}
App User: n8n_user
App Pass: ${POSTGRES_USER_PASS}

Segurança:
Runners Auth Token: ${RUNNERS_AUTH_TOKEN}

Diretório da Aplicação: ${APP_DIR}
====================================================
EOF
chmod 600 "$CRED_DIR/n8n.txt"

log_success "Instalação do n8n concluída!"
log_success "Acesso: http://${SERVER_IP}"
log_success "Porta: 80 (Nginx → 5678)"
log_success "Credenciais salvas em: $CRED_DIR/n8n.txt"
