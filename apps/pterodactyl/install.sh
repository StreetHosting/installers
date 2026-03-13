# Pterodactyl Panel Installer (Bare-Metal) for VirtFusion
# This script is designed to run non-interactively within a Cloud-Init context.

set -e

# Repository Configuration (Rule 2 & 3)
REPO_URL="https://raw.githubusercontent.com/StreetHosting/installers/stable"

# Run in background using systemd-run for persistence
if [[ "$1" != "--background" ]]; then
    # Ensure log file exists before backgrounding
    touch /var/log/strt_inst_pterodactyl.log
    chmod 644 /var/log/strt_inst_pterodactyl.log
    
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - Relançando o instalador em segundo plano via systemd-run para não bloquear o boot..." >> /var/log/strt_inst_pterodactyl.log
    
    # Save the script to a physical file if it was piped or is not in a stable location
    INSTALLER_PATH="/tmp/strt_inst_pterodactyl_exec.sh"
    if [ -f "$0" ] && [[ "$0" == *.sh ]]; then
        cat "$0" > "$INSTALLER_PATH"
    else
        # If piped (bash), download it from the repo
        curl -fsSL "$REPO_URL/apps/pterodactyl/install.sh" | sed 's/\r$//' > "$INSTALLER_PATH"
    fi
    chmod +x "$INSTALLER_PATH"
    
    # The command is wrapped in 'bash -c "..."' to handle the output redirection correctly
    systemd-run --unit=strt-inst-pterodactyl --on-active=1 --timer-property=AccuracySec=1s /bin/bash -c "$INSTALLER_PATH --background &>> /var/log/strt_inst_pterodactyl.log"
    exit 0
fi

# Ensure log file exists (redundancy for background process)
touch /var/log/strt_inst_pterodactyl.log
chmod 644 /var/log/strt_inst_pterodactyl.log

# Download Shared Utilities
curl -fsSL "$REPO_URL/shared/logging.sh?nocache=1" | sed 's/\r$//' > /tmp/logging.sh
source /tmp/logging.sh

# MOTD Setup (early - atualiza status durante a instalação)
curl -fsSL "$REPO_URL/shared/motd.sh?nocache=1" | sed 's/\r$//' > /tmp/motd.sh
source /tmp/motd.sh
motd_setup "pterodactyl"

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
sed -i "s|APP_TIMEZONE=.*|APP_TIMEZONE=America/Sao_Paulo|g" .env
sed -i "s|APP_SERVICE_AUTHOR=.*|APP_SERVICE_AUTHOR=development@streetworks.com.br|g" .env
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
  --email="admin@streetworks.com.br" \
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
Email: admin@streetworks.com.br
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

# Assistente de Configuração de Domínio
log_info "Instalando assistente de configuração de domínio..."
cat <<'EOF_DOMAIN_SETUP' > /usr/local/bin/street-domain-setup
#!/bin/bash
# StreetHosting - Assistente de Configuração de Domínio (Pterodactyl)

if [ "$(id -u)" -ne 0 ]; then
    printf "\033[38;2;255;60;60mEste assistente precisa ser executado como root.\033[0m\n"
    exit 1
fi

if [ "$1" != "--force" ] && [ -f /root/.street_domain_setup_done ]; then
    exit 0
fi

if [ "$1" != "--force" ]; then
    if ! grep -q "\[SUCCESS\]" /var/log/strt_inst_pterodactyl.log 2>/dev/null; then
        exit 0
    fi
fi

RST="\033[0m"
BLD="\033[1m"
DIM="\033[2m"
GOLD="\033[38;2;255;200;0m"
ORANGE="\033[38;2;255;165;0m"
YELLOW="\033[38;2;255;245;60m"
GREEN="\033[38;2;0;200;80m"
RED="\033[38;2;255;60;60m"
WHITE="\033[38;2;240;240;240m"
GRAY="\033[38;2;120;120;120m"
CYAN="\033[38;2;0;190;210m"
SEP_CLR="\033[38;2;60;60;60m"

_tw() {
    local text="$1" delay="${2:-0.015}"
    for ((i=0; i<${#text}; i++)); do
        printf "%s" "${text:$i:1}"
        sleep "$delay"
    done
}

_sep() {
    printf "  ${SEP_CLR}"
    for ((i=0; i<54; i++)); do printf "─"; done
    printf "${RST}\n"
}

_spin() {
    local pid=$1 msg="$2"
    local -a frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0 len=${#frames[@]}
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${GOLD}%s${RST} %b" "${frames[$i]}" "$msg"
        i=$(( (i + 1) % len ))
        sleep 0.08
    done
    wait "$pid"
    return $?
}

SERVER_IP=$(curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null)
[ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\./ && $i !~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)/) {print $i; exit}}')
[ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$SERVER_IP" ] && SERVER_IP="IP_DESCONHECIDO"

CURRENT_URL=""
if [ -f /var/www/pterodactyl/.env ]; then
    CURRENT_URL=$(grep -E '^APP_URL=' /var/www/pterodactyl/.env 2>/dev/null | sed 's/^APP_URL=//')
fi
[ -z "$CURRENT_URL" ] && CURRENT_URL="http://${SERVER_IP}"

echo ""
_sep
echo ""
printf "  ${BLD}${GOLD}"
_tw "✦  Configuração de Domínio" 0.025
printf "${RST}\n"
printf "  ${DIM}${GRAY}"
_tw "   Painel Pterodactyl" 0.02
printf "${RST}\n"
echo ""
_sep
echo ""
printf "  ${WHITE}Seu painel está acessível em:${RST}\n"
printf "  ${BLD}${CYAN}  → %s${RST}\n" "$CURRENT_URL"
echo ""
printf "  ${WHITE}Para usar um domínio personalizado,${RST}\n"
printf "  ${WHITE}crie um registro DNS tipo ${BLD}A${RST}${WHITE} apontando para:${RST}\n"
printf "  ${BLD}${YELLOW}  → %s${RST}\n" "$SERVER_IP"
echo ""
_sep
echo ""

read -p "$(printf "  ${BLD}${GOLD}Deseja configurar um domínio?${RST} ${DIM}(s/n)${RST}: ")" CONF_DOMAIN
echo ""

if [[ ! $CONF_DOMAIN =~ ^[Ss]$ ]]; then
    touch /root/.street_domain_setup_done
    printf "  ${DIM}${GRAY}Você pode executar este assistente novamente com:${RST}\n"
    printf "  ${GOLD}  street-domain-setup --force${RST}\n"
    echo ""
    exit 0
fi

read -p "$(printf "  ${BLD}${GOLD}Digite seu domínio${RST} ${DIM}(ex: painel.exemplo.com)${RST}: ")" DOMAIN_NAME
echo ""

if [ -z "$DOMAIN_NAME" ]; then
    printf "  ${RED}Domínio não informado. Operação cancelada.${RST}\n\n"
    exit 1
fi

printf "  ${WHITE}Aponte ${BLD}%s${RST}${WHITE} para ${BLD}%s${RST}${WHITE} (registro A)${RST}\n" "$DOMAIN_NAME" "$SERVER_IP"
printf "  ${DIM}${GRAY}Verificação automática — limite de 2 minutos${RST}\n"
echo ""

DNS_OK=0
TIMEOUT=120
DNS_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
DNS_FLEN=${#DNS_FRAMES[@]}
DNS_FI=0
DNS_RESULT=$(mktemp)
echo "" > "$DNS_RESULT"
START_TS=$(date +%s)

_resolve() {
    local domain="$1" result=""
    result=$(getent ahosts "$domain" 2>/dev/null | awk '$2=="STREAM" && $1 ~ /^[0-9]+\./{print $1; exit}')
    if [ -z "$result" ] && command -v dig >/dev/null 2>&1; then
        result=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    fi
    if [ -z "$result" ] && command -v host >/dev/null 2>&1; then
        result=$(host "$domain" 2>/dev/null | awk '/has address/{print $4}' | head -1)
    fi
    if [ -z "$result" ] && command -v nslookup >/dev/null 2>&1; then
        result=$(nslookup "$domain" 8.8.8.8 2>/dev/null | awk '/^Address/{ip=$NF} END{if(ip !~ /#/) print ip}')
    fi
    if [ -z "$result" ]; then
        result=$(curl -s --connect-timeout 3 "https://dns.google/resolve?name=${domain}&type=A" 2>/dev/null \
            | grep -o '"data":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    echo "$result"
}

(
    while true; do
        r=$(_resolve "$DOMAIN_NAME")
        echo "$r" > "$DNS_RESULT"
        sleep 3
    done
) &
DNS_PID=$!

trap "kill $DNS_PID 2>/dev/null; rm -f '$DNS_RESULT'" EXIT

while true; do
    NOW_TS=$(date +%s)
    ELAPSED=$((NOW_TS - START_TS))

    if [ $ELAPSED -ge $TIMEOUT ]; then
        break
    fi

    RESOLVED=$(cat "$DNS_RESULT" 2>/dev/null | tr -d '[:space:]')

    if [ "$RESOLVED" = "$SERVER_IP" ]; then
        DNS_OK=1
        printf "\r  ${GREEN}✓${RST} ${WHITE}DNS verificado! ${BLD}%s${RST}${WHITE} → ${BLD}%s${RST}                              \n" "$DOMAIN_NAME" "$SERVER_IP"
        break
    fi

    REMAINING=$((TIMEOUT - ELAPSED))
    [ $REMAINING -lt 0 ] && REMAINING=0
    MINS=$((REMAINING / 60))
    SECS=$((REMAINING % 60))

    if [ -n "$RESOLVED" ] && [ "$RESOLVED" != "$SERVER_IP" ]; then
        printf "\r  ${GOLD}%s${RST} ${WHITE}Aguardando DNS...${RST} ${DIM}${GRAY}%d:%02d · aponta para %s${RST}      " "${DNS_FRAMES[$DNS_FI]}" "$MINS" "$SECS" "$RESOLVED"
    else
        printf "\r  ${GOLD}%s${RST} ${WHITE}Aguardando DNS...${RST} ${DIM}${GRAY}%d:%02d restantes${RST}              " "${DNS_FRAMES[$DNS_FI]}" "$MINS" "$SECS"
    fi
    DNS_FI=$(( (DNS_FI + 1) % DNS_FLEN ))

    sleep 0.08
done

kill $DNS_PID 2>/dev/null
wait $DNS_PID 2>/dev/null
rm -f "$DNS_RESULT"
trap - EXIT

if [ $DNS_OK -eq 0 ]; then
    echo ""
    printf "  ${RED}✗${RST} ${WHITE}Tempo esgotado. DNS não propagou em 2 minutos.${RST}\n"
    printf "  ${DIM}${GRAY}  Verifique a configuração e tente novamente com:${RST}\n"
    printf "  ${GOLD}  street-domain-setup --force${RST}\n"
    echo ""
    exit 1
fi

echo ""

(
    sed -i "s/server_name .*/server_name $DOMAIN_NAME;/g" /etc/nginx/sites-available/pterodactyl.conf
    systemctl reload nginx
) &>/dev/null &
_spin $! "${WHITE}Configurando Nginx...${RST}"
if [ $? -eq 0 ]; then
    printf "\r  ${GREEN}✓${RST} ${WHITE}Nginx configurado!${RST}                                          \n"
else
    printf "\r  ${RED}✗${RST} ${WHITE}Falha ao configurar Nginx.${RST}                                  \n"
fi

(
    certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --register-unsafely-without-email
) &>/dev/null &
_spin $! "${WHITE}Gerando certificado SSL com Let's Encrypt...${RST}"
CERT_EXIT=$?

if [ $CERT_EXIT -eq 0 ]; then
    printf "\r  ${GREEN}✓${RST} ${WHITE}Certificado SSL instalado!${RST}                                  \n"
    NEW_URL="https://$DOMAIN_NAME"
else
    printf "\r  ${RED}✗${RST} ${WHITE}Falha ao gerar SSL. Usando HTTP.${RST}                             \n"
    printf "  ${DIM}${GRAY}  Verifique se o DNS está correto e tente novamente.${RST}\n"
    NEW_URL="http://$DOMAIN_NAME"
fi

(
    cd /var/www/pterodactyl
    sed -i "s|APP_URL=.*|APP_URL=$NEW_URL|g" .env
    php artisan config:clear
    php artisan route:clear
    php artisan cache:clear
) &>/dev/null &
_spin $! "${WHITE}Atualizando configuração do Pterodactyl...${RST}"
printf "\r  ${GREEN}✓${RST} ${WHITE}Pterodactyl atualizado!${RST}                                      \n"

CRED_FILE="/etc/street_preinstallers/credentials/pterodactyl.txt"
if [ -f "$CRED_FILE" ]; then
    sed -i "s|URL: .*|URL: $NEW_URL|g" "$CRED_FILE"
fi

echo ""
_sep
echo ""
printf "  ${BLD}${GREEN}"
_tw "✓ Configuração concluída!" 0.025
printf "${RST}\n"
echo ""
printf "  ${WHITE}Seu painel está disponível em:${RST}\n"
printf "  ${BLD}${CYAN}  → %s${RST}\n" "$NEW_URL"
echo ""
_sep
echo ""

touch /root/.street_domain_setup_done
EOF_DOMAIN_SETUP

chmod +x /usr/local/bin/street-domain-setup

if ! grep -q "street-domain-setup" /root/.bashrc; then
    cat <<'EOF_BASHRC' >> /root/.bashrc

# StreetHosting - Assistente de Domínio
if [[ $- == *i* ]] && [ -x /usr/local/bin/street-domain-setup ]; then
    /usr/local/bin/street-domain-setup
fi
EOF_BASHRC
fi

log_success "Instalação do Painel Pterodactyl concluída!"
log_success "Acesso: http://${SERVER_IP}"
log_success "Credenciais salvas em: $CRED_DIR/pterodactyl.txt"
