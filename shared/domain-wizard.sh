# Domain wizard utilities for VirtFusion Provisioners
# Installs Nginx reverse proxy and interactive domain configuration wizard

if ! type log_info &>/dev/null; then
    log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
    log_warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
    log_success() { echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
fi

install_nginx_proxy() {
    local app_id="$1"
    local server_ip="$2"
    local upstream_port="$3"

    log_info "Instalando Nginx e Certbot..."
    if ! command -v nginx >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot python3-certbot-nginx
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx || true
    fi

    systemctl enable --now nginx

    log_info "Configurando proxy reverso Nginx para ${app_id}..."
    cat <<NGINX_EOF > "/etc/nginx/sites-available/${app_id}.conf"
server {
    listen 80;
    server_name ${server_ip};

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:${upstream_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
    }
}
NGINX_EOF

    ln -sf "/etc/nginx/sites-available/${app_id}.conf" "/etc/nginx/sites-enabled/${app_id}.conf"
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx

    log_success "Proxy reverso Nginx configurado (porta 80 → ${upstream_port})."
}

install_domain_wizard() {
    local app_id="$1"
    local display_name="$2"
    local log_file="$3"

    log_info "Instalando assistente de configuração de domínio..."

    mkdir -p /etc/street_preinstallers

    cat > /etc/street_preinstallers/domain-wizard.conf <<CONF_EOF
APP_ID="${app_id}"
APP_DISPLAY_NAME="${display_name}"
LOG_FILE="${log_file}"
NGINX_SITE="${app_id}"
CRED_FILE="/etc/street_preinstallers/credentials/${app_id}.txt"
CONF_EOF

    cat <<'WIZARD_EOF' > /usr/local/bin/street-domain-setup
#!/bin/bash
# StreetHosting - Assistente de Configuração de Domínio

CONF_FILE="/etc/street_preinstallers/domain-wizard.conf"
[ -f "$CONF_FILE" ] || exit 0
source "$CONF_FILE"

if [ "$(id -u)" -ne 0 ]; then
    printf "\033[38;2;255;60;60mEste assistente precisa ser executado como root.\033[0m\n"
    exit 1
fi

if [ "$1" != "--force" ] && [ -f /root/.street_domain_setup_done ]; then
    exit 0
fi

if [ "$1" != "--force" ]; then
    if ! grep -q "\[SUCCESS\]" "$LOG_FILE" 2>/dev/null; then
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

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s https://ifconfig.me 2>/dev/null || echo "IP_DESCONHECIDO")

CURRENT_URL="${CONFIGURED_URL:-http://${SERVER_IP}}"

echo ""
_sep
echo ""
printf "  ${BLD}${GOLD}"
_tw "✦  Configuração de Domínio" 0.025
printf "${RST}\n"
printf "  ${DIM}${GRAY}"
_tw "   ${APP_DISPLAY_NAME}" 0.02
printf "${RST}\n"
echo ""
_sep
echo ""
printf "  ${WHITE}Seu app está acessível em:${RST}\n"
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

read -p "$(printf "  ${BLD}${GOLD}Digite seu domínio${RST} ${DIM}(ex: app.exemplo.com)${RST}: ")" DOMAIN_NAME
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
    result=$(getent ahosts "$domain" 2>/dev/null | awk '/STREAM/{print $1; exit}')
    if [ -z "$result" ] && command -v dig >/dev/null 2>&1; then
        result=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    fi
    if [ -z "$result" ] && command -v host >/dev/null 2>&1; then
        result=$(host "$domain" 2>/dev/null | awk '/has address/{print $4}' | head -1)
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
    sed -i "s/server_name .*/server_name $DOMAIN_NAME;/g" "/etc/nginx/sites-available/${NGINX_SITE}.conf"
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

export DOMAIN_NAME NEW_URL SERVER_IP
HOOK_FILE="/etc/street_preinstallers/domain-hook.sh"
if [ -f "$HOOK_FILE" ] && [ -x "$HOOK_FILE" ]; then
    (
        bash "$HOOK_FILE"
    ) &>/dev/null &
    _spin $! "${WHITE}Atualizando configuração do ${APP_DISPLAY_NAME}...${RST}"
    printf "\r  ${GREEN}✓${RST} ${WHITE}${APP_DISPLAY_NAME} atualizado!${RST}                                      \n"
fi

if [ -f "$CRED_FILE" ]; then
    sed -i "s|Acesso: .*|Acesso: $NEW_URL|g" "$CRED_FILE"
    sed -i "s|URL: .*|URL: $NEW_URL|g" "$CRED_FILE"
fi

sed -i '/^CONFIGURED_URL=/d' "$CONF_FILE" 2>/dev/null
echo "CONFIGURED_URL=$NEW_URL" >> "$CONF_FILE"

echo ""
_sep
echo ""
printf "  ${BLD}${GREEN}"
_tw "✓ Configuração concluída!" 0.025
printf "${RST}\n"
echo ""
printf "  ${WHITE}Seu app está disponível em:${RST}\n"
printf "  ${BLD}${CYAN}  → %s${RST}\n" "$NEW_URL"
echo ""
_sep
echo ""

touch /root/.street_domain_setup_done
WIZARD_EOF

    chmod +x /usr/local/bin/street-domain-setup

    if ! grep -q "street-domain-setup" /root/.bashrc 2>/dev/null; then
        cat <<'BASHRC_EOF' >> /root/.bashrc

# StreetHosting - Assistente de Domínio
if [[ $- == *i* ]] && [ -x /usr/local/bin/street-domain-setup ]; then
    /usr/local/bin/street-domain-setup
fi
BASHRC_EOF
    fi

    log_success "Assistente de domínio instalado."
}
