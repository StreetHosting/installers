# Pterodactyl Panel Installer for VirtFusion
# This script is designed to run non-interactively within a Cloud-Init context.

set -e

# Network Initialization (Rule 9)
# sleep 15 # Removed temporarily for testing (just for debugging!)

# Repository Configuration (Rule 2 & 3)
REPO_URL="https://raw.githubusercontent.com/StreetHosting/installers/stable"

# Download Shared Utilities (Rule 21 & 28)
curl -fsSL "$REPO_URL/shared/logging.sh?nocache=1" | sed 's/\r$//' > /tmp/logging.sh
curl -fsSL "$REPO_URL/shared/docker.sh?nocache=1" | sed 's/\r$//' > /tmp/docker.sh

# Source Utilities
source /tmp/logging.sh
source /tmp/docker.sh

log_info "Iniciando o processo de instalação do Painel Pterodactyl..."

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

# Install basic dependencies
log_info "Instalando dependências básicas..."
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y openssl curl gnupg

# Install Docker (Rule 6 & 7)
install_docker

# Install Nginx on host for reverse proxy
log_info "Instalando Nginx no host para o reverse proxy..."
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot python3-certbot-nginx

# Application Isolation & Data Persistence (Rule 27 & 31)
APP_DIR="/opt/apps/pterodactyl"
log_info "Configurando o diretório da aplicação: $APP_DIR"
mkdir -p "$APP_DIR/var"
mkdir -p "$APP_DIR/nginx"
mkdir -p "$APP_DIR/db"
cd "$APP_DIR"

# Get Public IP for configuration
SERVER_IP=$(curl -s https://ifconfig.me || echo "SERVER_IP")

# Generate Random Passwords (Rule 5)
MYSQL_ROOT_PASS=$(openssl rand -hex 16)
MYSQL_PASSWORD=$(openssl rand -hex 16)
# Pterodactyl requires a 32-character base64 encoded key for AES-256-CBC
PTERO_APP_KEY="base64:$(openssl rand -base64 32)"

log_info "Gerando a configuração do Docker Compose..."
cat <<EOF > docker-compose.yml
services:
  database:
    image: mariadb:10.11
    restart: always
    command: --default-authentication-plugin=mysql_native_password
    volumes:
      - ./db:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
      - MYSQL_DATABASE=panel
      - MYSQL_USER=pterodactyl
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}

  cache:
    image: redis:7-alpine
    restart: always

  panel:
    image: ghcr.io/pterodactyl/panel:latest
    restart: always
    ports:
      - "8080:80"
    links:
      - database
      - cache
    volumes:
      - ./var/:/app/var/
      - /etc/localtime:/etc/localtime:ro
    environment:
      - APP_URL=http://${SERVER_IP}
      - APP_TIMEZONE=UTC
      - APP_SERVICE_AUTHOR=admin@example.com
      - APP_KEY=${PTERO_APP_KEY}
      - DB_HOST=database
      - DB_PORT=3306
      - DB_DATABASE=panel
      - DB_USERNAME=pterodactyl
      - DB_PASSWORD=${MYSQL_PASSWORD}
      - CACHE_DRIVER=redis
      - SESSION_DRIVER=redis
      - QUEUE_CONNECTION=redis
      - REDIS_HOST=cache
      - REDIS_PORT=6379
EOF

# Start Application (Rule 23)
log_info "Iniciando os containers do Painel Pterodactyl..."
if ! docker compose up -d; then
    log_error "O Docker Compose falhou ao iniciar a stack."
    exit 1
fi

# Initializing Pterodactyl (Create User and migrate)
log_info "Executando migrações e configuração inicial (isso pode levar um minuto)..."

# Wait for containers to be ready and install dependencies
log_info "Aguardando os containers e instalando cliente MariaDB..."
MAX_RETRIES=30
COUNT=0
# Temporarily disable set -e to handle migration retry logic
set +e

# Install mysql client inside the container (required for schema loading)
# We do this in a loop with a limit to avoid blocking the system forever
until docker compose exec -T panel apk add --no-cache mariadb-client || [ $COUNT -eq $MAX_RETRIES ]; do
    COUNT=$((COUNT + 1))
    log_info "Aguardando container estar pronto para instalar dependências... ($COUNT/$MAX_RETRIES)"
    sleep 10
done

if [ $COUNT -eq $MAX_RETRIES ]; then
    log_error "O container do Painel não ficou pronto a tempo. Abortando para evitar bloqueio do sistema."
    docker compose logs panel
    exit 1
fi

# Reset count for migrations
COUNT=0
until docker compose exec -T panel php artisan migrate --seed --force || [ $COUNT -eq $MAX_RETRIES ]; do
    COUNT=$((COUNT + 1))
    log_info "Aguardando o banco de dados e containers para migração... ($COUNT/$MAX_RETRIES)"
    sleep 10
done

if [ $COUNT -eq $MAX_RETRIES ]; then
    log_error "As migrações falharam após $MAX_RETRIES tentativas."
    docker compose logs database
    exit 1
fi
set -e

# Create Initial Admin User (non-interactive)
# Pterodactyl doesn't have a non-interactive artisan command for user creation with all fields.
# We will create it via tinker or raw SQL, or just skip it and let user create on first login if possible.
# Actually, Pterodactyl REQUIRES an admin user.
log_info "Criando usuário administrador inicial..."
ADMIN_PASS=$(openssl rand -hex 8)
docker compose exec -T panel php artisan p:user:make \
  --email="admin@example.com" \
  --username="admin" \
  --name-first="Admin" \
  --name-last="User" \
  --password="${ADMIN_PASS}" \
  --admin=1

# Configure Nginx on host
log_info "Configurando o reverse proxy do Nginx..."
cat <<EOF > /etc/nginx/sites-available/pterodactyl
server {
    listen 80;
    server_name ${SERVER_IP};

    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
    }
}
EOF
ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/pterodactyl
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

# Create the Post-Install Setup Script
log_info "Criando script de configuração inicial (primeiro login)..."
cat <<'EOF_SETUP' > /usr/local/bin/pterodactyl-setup
#!/bin/bash

if [ -f /root/.pterodactyl_setup_done ]; then
    exit 0
fi

clear
echo "===================================================="
echo "    Painel Pterodactyl - Configuração Final"
echo "===================================================="
echo ""
read -p "Deseja configurar um nome de domínio agora? (s/n): " CONF_DOMAIN

if [[ $CONF_DOMAIN =~ ^[Ss]$ ]]; then
    read -p "Digite seu domínio (ex: painel.exemplo.com): " DOMAIN_NAME
    
    echo ""
    echo "Certifique-se de que seu domínio $DOMAIN_NAME está apontando para o IP desta VPS: $(curl -s https://ifconfig.me)"
    read -p "Pressione [Enter] assim que o DNS estiver apontado..."
    
    echo "Gerando certificado SSL com Let's Encrypt..."
    if certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --register-unsafely-without-email; then
        echo "SSL configurado com sucesso!"
        
        # Update Pterodactyl APP_URL
        cd /opt/apps/pterodactyl
        sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN_NAME|g" docker-compose.yml
        docker compose up -d
        
        echo "Atualizando configuração do Pterodactyl..."
        docker compose exec -T panel php artisan p:environment:setup --url="https://$DOMAIN_NAME"
        
        echo "Sucesso! Seu painel agora está disponível em https://$DOMAIN_NAME"
    else
        echo "Falha ao gerar o SSL. Verifique seu DNS e tente novamente mais tarde."
    fi
fi

touch /root/.pterodactyl_setup_done
echo ""
echo "Configuração concluída. Você já pode acessar seu painel."
echo "===================================================="
EOF_SETUP

chmod +x /usr/local/bin/pterodactyl-setup

# Add hook to .bashrc for root
if ! grep -q "pterodactyl-setup" /root/.bashrc; then
    cat <<'EOF_BASHRC' >> /root/.bashrc

# Pterodactyl Setup Hook
if [[ $- == *i* ]] && [ -x /usr/local/bin/pterodactyl-setup ]; then
    /usr/local/bin/pterodactyl-setup
fi
EOF_BASHRC
fi

log_success "Instalação do Painel Pterodactyl concluída!"
log_success "Acesso: http://${SERVER_IP}"
log_success "Credenciais Iniciais do Administrador:"
log_success "Email: admin@example.com"
log_success "Senha: ${ADMIN_PASS}"
log_info "-------------------------------------------"
log_info "Senha Root do MySQL: ${MYSQL_ROOT_PASS}"
log_info "Senha do Usuário MySQL: ${MYSQL_PASSWORD}"
log_info "-------------------------------------------"
log_info "A configuração de Domínio/SSL será solicitada no próximo login SSH."
