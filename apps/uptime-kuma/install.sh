#!/usr/bin/env bash
set -e

# Uptime Kuma Installer for VirtFusion
# This script is designed to run non-interactively within a Cloud-Init context.

# Network Initialization (Rule 9)
# Assume the network may not be fully ready at boot.
sleep 15

# Repository Configuration (Rule 2 & 3)
# Always reference the stable branch for production installers.
REPO_URL="https://raw.githubusercontent.com/StreetHosting/installers/stable"

# Download Shared Utilities (Rule 21 & 28)
# Normalize line endings to prevent execution errors on Linux.
curl -fsSL "$REPO_URL/shared/logging.sh?nocache=1" | sed 's/\r$//' > /tmp/logging.sh
curl -fsSL "$REPO_URL/shared/docker.sh?nocache=1" | sed 's/\r$//' > /tmp/docker.sh

# Source Utilities
source /tmp/logging.sh
source /tmp/docker.sh

log_info "Starting Uptime Kuma installation process..."

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
APP_DIR="/opt/apps/uptime-kuma"
log_info "Setting up application directory: $APP_DIR"
mkdir -p "$APP_DIR/data"

cd "$APP_DIR"

# Get Public IP for configuration
SERVER_IP=$(curl -s https://ifconfig.me || echo "SERVER_IP")

# Deploy Uptime Kuma using Docker Compose (Rule 6)
log_info "Creating Docker Compose configuration..."
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
log_info "Starting Uptime Kuma container..."
docker compose up -d

# Final Access Information (Rule 10)
log_success "Uptime Kuma installation complete!"
log_info "Access: http://${SERVER_IP}:3001"
log_info "Port: 3001"
