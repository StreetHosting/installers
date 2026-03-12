# n8n Installer for VirtFusion
# This script is designed to run non-interactively within a Cloud-Init context.

# Network Initialization (Rule 9)
# Assume the network may not be fully ready at boot.
sleep 15

# Repository Configuration (Rule 2 & 3)
# Always reference the stable branch for production installers.
REPO_URL="https://raw.githubusercontent.com/StreetHosting/installers/stable"

# Download Shared Utilities (Rule 21 & 28)
# Normalize line endings to prevent execution errors on Linux.
curl -fsSL "$REPO_URL/shared/logging.sh" | sed 's/\r$//' > /tmp/logging.sh
curl -fsSL "$REPO_URL/shared/docker.sh" | sed 's/\r$//' > /tmp/docker.sh

# Source Utilities
source /tmp/logging.sh
source /tmp/docker.sh

log_info "Starting n8n installation process..."

# OS Detection & Validation (Rule 4)
if [ -f /etc/os-release ]; then
    source /etc/os-release
    log_info "Detected OS: $NAME $VERSION_ID"
else
    log_error "Could not detect operating system."
    exit 1
fi

# Ensure APT-based system (Rule 4)
if ! command -v apt-get >/dev/null 2>&1; then
    log_error "This installer only supports APT-based systems (Ubuntu/Debian)."
    exit 1
fi

# Install Docker (Rule 6 & 7)
# This utility handles idempotency and non-interactive installation.
install_docker

# Application Isolation & Data Persistence (Rule 27 & 31)
APP_DIR="/opt/apps/n8n"
log_info "Setting up application directory: $APP_DIR"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# Get Public IP for configuration
SERVER_IP=$(curl -s https://ifconfig.me || echo "SERVER_IP")

# Deploy n8n using Docker Compose (Rule 6)
log_info "Creating Docker Compose configuration..."
cat <<EOF > docker-compose.yml
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: n8n
    restart: always
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=${SERVER_IP}
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - NODE_ENV=production
      - WEBHOOK_URL=http://${SERVER_IP}:5678/
    volumes:
      - ./n8n_data:/home/node/.n8n
EOF

# Start Application (Rule 23)
log_info "Launching n8n container..."
docker compose up -d

# Verify Installation
if [ "$(docker ps -q -f name=n8n)" ]; then
    log_success "n8n has been successfully installed and started."
    log_success "Access: http://${SERVER_IP}:5678"
    log_success "Port: 5678"
else
    log_error "n8n container failed to start."
    exit 1
fi
