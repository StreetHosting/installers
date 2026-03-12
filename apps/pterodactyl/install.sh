# Pterodactyl Panel Installer (Bare-Metal) for VirtFusion
# This script is designed to run non-interactively within a Cloud-Init context.

set -e

# Network Initialization (Rule 9)
sleep 15

# Repository Configuration (Rule 2 & 3)
REPO_URL="https://raw.githubusercontent.com/StreetHosting/installers/stable"

# Download Shared Utilities
curl -fsSL "$REPO_URL/shared/logging.sh?nocache=1" | sed 's/\r$//' > /tmp/logging.sh
source /tmp/logging.sh

# Run in background using systemd-run for persistence
if [[ "$1" != "--background" ]]; then
    log_info "Relançando o instalador em segundo plano via systemd-run para não bloquear o boot..."
    # The command is wrapped in 'bash -c "..."' to handle the output redirection correctly
    systemd-run --unit=strt-inst-pterodactyl --on-active=3 --timer-property=AccuracySec=1s bash -c "/bin/bash $0 --background &>> /var/log/strt_inst_pterodactyl.log"
    exit 0
fi

log_info "Executando em segundo plano. Logs disponíveis em /var/log/strt_inst_pterodactyl.log"

# Ensure log file exists
touch /var/log/strt_inst_pterodactyl.log
chmod 644 /var/log/strt_inst_pterodactyl.log

log_info "Iniciando o processo de instalação do Painel Pterodactyl (Bare-Metal)..."

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

# Update and install basic tools
log_info "Atualizando o sistema e instalando ferramentas básicas..."
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y openssl curl gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common git tar unzip

# Setup MariaDB Repository
log_info "Configurando repositório do MariaDB..."
if [[ "$ID" == "ubuntu" ]]; then
    # Ubuntu 24.04 (Noble) has MariaDB 10.11+ in main repos
    # Ubuntu 22.04 (Jammy) has 10.6, which is fine, but we prefer 10.11
    if [[ "$VERSION_ID" != "24.04" ]]; then
        curl -LsSo /etc/apt/trusted.gpg.d/mariadb.gpg https://mariadb.org/mariadb_release_signing_key.asc
        add-apt-repository -y "deb [arch=amd64,arm64] https://mirror.mariadb.org/repo/10.11/ubuntu $VERSION_CODENAME main"
    fi
elif [[ "$ID" == "debian" ]]; then
    curl -LsSo /etc/apt/trusted.gpg.d/mariadb.gpg https://mariadb.org/mariadb_release_signing_key.asc
    add-apt-repository -y "deb [arch=amd64,arm64] https://mirror.mariadb.org/repo/10.11/debian $VERSION_CODENAME main"
fi

# Setup PHP 8.3 Repository
log_info "Configurando repositório do PHP 8.3..."
if [[ "$ID" == "ubuntu" ]]; then
    if [[ "$VERSION_ID" != "24.04" ]]; then
        add-apt-repository -y ppa:ondrej/php
    fi
elif [[ "$ID" == "debian" ]]; then
    curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $VERSION_CODENAME main" > /etc/apt/sources.list.d/php.list
fi

DEBIAN_FRONTEND=noninteractive apt-get update -y

# Install Dependencies (Rule 11)
log_info "Instalando PHP 8.3, MariaDB, Redis e Nginx..."
DEBIAN_FRONTEND=noninteractive apt-get install -y php8.3 php8.3-common php8.3-cli php8.3-gd php8.3-mysql php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip php8.3-fpm php8.3-intl php8.3-sqlite3 mariadb-server redis-server nginx certbot python3-certbot-nginx

# Start and Enable Services
systemctl enable --now mariadb
systemctl enable --now redis-server
systemctl enable --now nginx
systemctl enable --now php8.3-fpm

# Database Setup
log_info "Configurando o banco de dados..."
MYSQL_ROOT_PASS=$(openssl rand -hex 16)
MYSQL_PTERO_PASS=$(openssl rand -hex 16)

# Secure MariaDB
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
CREATE DATABASE IF NOT EXISTS panel;
CREATE USER IF NOT EXISTS 'pterodactyl'@'localhost' IDENTIFIED BY '${MYSQL_PTERO_PASS}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Install Composer
log_info "Instalando Composer..."
export HOME=/root
export COMPOSER_HOME=/root/.composer
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Download Pterodactyl (Rule 14 & User request)
log_info "Baixando o Painel Pterodactyl em /var/www/pterodactyl..."
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Configure Environment
log_info "Configurando ambiente (.env)..."
SERVER_IP=$(curl -s https://ifconfig.me || echo "SERVER_IP")
PTERO_APP_KEY="base64:$(openssl rand -base64 32)"

cp .env.example .env
sed -i "s|APP_URL=.*|APP_URL=http://${SERVER_IP}|g" .env
sed -i "s|APP_KEY=.*|APP_KEY=${PTERO_APP_KEY}|g" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${MYSQL_PTERO_PASS}|g" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=pterodactyl|g" .env
sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|g" .env
sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|g" .env
sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|g" .env
sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|g" .env

# Install PHP Dependencies
log_info "Executando composer install..."
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --optimize-autoloader

# Run Migrations and Seeders
log_info "Executando migrações do banco de dados..."
php artisan migrate --seed --force

# Create Initial Admin User
log_info "Criando usuário administrador inicial..."
ADMIN_PASS=$(openssl rand -hex 8)
php artisan p:user:make \
  --email="admin@example.com" \
  --username="admin" \
  --name-first="Admin" \
  --name-last="User" \
  --password="${ADMIN_PASS}" \
  --admin=1

# Set Permissions
log_info "Configurando permissões (www-data)..."
chown -R www-data:www-data /var/www/pterodactyl/*

# Setup Crontab
log_info "Configurando Crontab..."
(crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

# Setup Queue Worker (Systemd)
log_info "Configurando Queue Worker (pteroq.service)..."
cat <<EOF > /etc/systemd/system/pteroq.service
# Pterodactyl Queue Worker File
# ----------------------------------

[Unit]
Description=Pterodactyl Queue Worker
After=network.target

[Service]
# On some systems the user and group might be different.
# Some systems use `apache` or `nginx` as the user and group.
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now pteroq.service

# Configure Nginx
log_info "Configurando Nginx..."
cat <<EOF > /etc/nginx/sites-available/pterodactyl.conf
server {
    listen 80;
    server_name ${SERVER_IP};

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    # allow larger file uploads and longer script runtimes
    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

# Save Credentials
log_info "Salvando credenciais em /etc/street_preinstallers/credentials/pterodactyl.txt..."
CRED_DIR="/etc/street_preinstallers/credentials"
mkdir -p "$CRED_DIR"
cat <<EOF > "$CRED_DIR/pterodactyl.txt"
====================================================
Painel Pterodactyl (Bare-Metal) - Credenciais
Gerado em: $(date)
====================================================

Painel (Admin Inicial):
URL: http://${SERVER_IP}
Email: admin@example.com
Username: admin
Senha: ${ADMIN_PASS}

Banco de Dados (MariaDB):
Database: panel
Username: pterodactyl
Password: ${MYSQL_PTERO_PASS}
Root Password: ${MYSQL_ROOT_PASS}

Caminho da Instalação: /var/www/pterodactyl
Segurança:
APP_KEY: ${PTERO_APP_KEY}
====================================================
EOF
chmod 600 "$CRED_DIR/pterodactyl.txt"

# Create the Post-Install Setup Script
log_info "Criando script de configuração final (Domínio/SSL)..."
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
        
        # Update Pterodactyl config
        cd /var/www/pterodactyl
        sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN_NAME|g" .env
        php artisan p:environment:setup --url="https://$DOMAIN_NAME"
        
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
log_success "Credenciais salvas em: $CRED_DIR/pterodactyl.txt"
