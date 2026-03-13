# MOTD utilities for VirtFusion Provisioners
# Configures a dynamic MOTD with STREETHOSTING gradient banner and app info (pt-BR)

if ! type log_info &>/dev/null; then
    log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
    log_warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
    log_success() { echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
fi

motd_setup() {
    local app_id="$1"

    if [ -z "$app_id" ]; then
        log_warn "motd_setup: APP_ID não fornecido, pulando configuração do MOTD."
        return 0
    fi

    log_info "Configurando MOTD dinâmico para: $app_id"

    if ! command -v figlet >/dev/null 2>&1; then
        log_info "Instalando figlet..."
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y figlet >/dev/null 2>&1 || log_warn "Falha ao instalar figlet, o MOTD usará texto simples."
    fi

    mkdir -p /etc/street_preinstallers
    cat > /etc/street_preinstallers/motd.conf <<MOTD_CONF
INSTALLED_APP=${app_id}
MOTD_CONF

    cat > /etc/update-motd.d/50-street-app <<'MOTD_SCRIPT'
#!/bin/bash
CONF_FILE="/etc/street_preinstallers/motd.conf"
[ -f "$CONF_FILE" ] || exit 0
source "$CONF_FILE"
[ -n "$INSTALLED_APP" ] || exit 0

_get_display_name() {
    case "$1" in
        n8n) echo "n8n" ;;
        uptime-kuma) echo "Uptime Kuma" ;;
        pterodactyl) echo "Painel Pterodactyl" ;;
        *) echo "$1" ;;
    esac
}

_get_environment_tag() {
    case "$1" in
        pterodactyl) echo "Ambiente Pterodactyl" ;;
        *) echo "" ;;
    esac
}

_get_log_file() {
    case "$1" in
        n8n) echo "/var/log/strt_inst_n8n.log" ;;
        uptime-kuma) echo "/var/log/strt_inst_uptime_kuma.log" ;;
        pterodactyl) echo "/var/log/strt_inst_pterodactyl.log" ;;
        *) echo "/var/log/strt_inst_${1}.log" ;;
    esac
}

_get_access_url() {
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$server_ip" ] && server_ip="IP_DO_SERVIDOR"

    local conf_file="/etc/street_preinstallers/domain-wizard.conf"
    if [ -f "$conf_file" ]; then
        local conf_url
        conf_url=$(grep -E '^CONFIGURED_URL=' "$conf_file" 2>/dev/null | sed 's/^CONFIGURED_URL=//')
        if [ -n "$conf_url" ]; then
            echo "$conf_url"
            return
        fi
        echo "http://${server_ip}"
        return
    fi

    case "$1" in
        pterodactyl)
            if [ -f /var/www/pterodactyl/.env ]; then
                local app_url
                app_url=$(grep -E '^APP_URL=' /var/www/pterodactyl/.env 2>/dev/null | sed 's/^APP_URL=//')
                [ -n "$app_url" ] && { echo "$app_url"; return; }
            fi
            echo "http://${server_ip}"
            ;;
        n8n) echo "http://${server_ip}:5678" ;;
        uptime-kuma) echo "http://${server_ip}:3001" ;;
        *) echo "http://${server_ip}" ;;
    esac
}

echo ""

if command -v figlet >/dev/null 2>&1; then
    figlet -f slant "STREETHOSTING" 2>/dev/null | awk '
    {
        lines[NR] = $0
        len = length($0)
        if (len > max_w) max_w = len
    }
    END {
        if (max_w == 0) max_w = 1
        for (n = 1; n <= NR; n++) {
            line = lines[n]
            len = length(line)
            printf "  "
            for (i = 1; i <= len; i++) {
                c = substr(line, i, 1)
                if (c == " ") { printf " "; continue }
                ratio = (i - 1) / max_w
                if (ratio < 0.5) {
                    t = ratio * 2
                    R = 255; G = int(185 + 60 * t); B = int(15 + 45 * t)
                } else {
                    t = (ratio - 0.5) * 2
                    R = 255; G = int(245 - 115 * t); B = int(60 - 60 * t)
                }
                printf "\033[38;2;%d;%d;%dm%s", R, G, B, c
            }
            printf "\033[0m\n"
        }
    }'
else
    printf "  \033[1;38;2;255;200;0mSTREETHOSTING\033[0m\n"
fi

APP_NAME=$(_get_display_name "$INSTALLED_APP")
ENV_TAG=$(_get_environment_tag "$INSTALLED_APP")
LOG_FILE=$(_get_log_file "$INSTALLED_APP")
ACCESS_URL=$(_get_access_url "$INSTALLED_APP")
CRED_FILE="/etc/street_preinstallers/credentials/${INSTALLED_APP}.txt"

echo ""

if [ -n "$ENV_TAG" ]; then
    printf "  \033[1;38;2;255;165;0m    %s\033[0m\n\n" "$ENV_TAG"
fi

printf "  \033[38;2;255;200;0mAplicação:\033[0m  %s\n" "$APP_NAME"
printf "  \033[38;2;255;200;0mAcesso:\033[0m     %s\n" "$ACCESS_URL"

if [ -f "$LOG_FILE" ]; then
    LAST_LOG=$(grep -E '^\[(SUCCESS|ERROR|INFO)\]' "$LOG_FILE" 2>/dev/null | tail -1)
    if echo "$LAST_LOG" | grep -q "\[SUCCESS\]"; then
        printf "  \033[38;2;255;200;0mStatus:\033[0m     \033[38;2;0;200;0m● Instalação concluída\033[0m\n"
    elif echo "$LAST_LOG" | grep -q "\[ERROR\]"; then
        printf "  \033[38;2;255;200;0mStatus:\033[0m     \033[38;2;255;60;60m● Erro na instalação\033[0m\n"
    else
        printf "  \033[38;2;255;200;0mStatus:\033[0m     \033[38;2;255;255;0m● Instalação em andamento...\033[0m\n"
    fi
else
    printf "  \033[38;2;255;200;0mStatus:\033[0m     \033[38;2;255;255;0m● Aguardando instalação...\033[0m\n"
fi

echo ""
printf "  \033[2;38;2;100;100;100m────────────────────────────────────────────────\033[0m\n"
echo ""
printf "  \033[38;2;200;200;200mStatus da instalação:\033[0m\n"
printf "    \033[2mtail -20 %s\033[0m\n" "$LOG_FILE"
printf "    \033[2mem tempo real, use: tail -f %s\033[0m\n" "$LOG_FILE  "
echo ""
printf "  \033[38;2;200;200;200mCredenciais de acesso:\033[0m\n"
printf "    \033[2mcat %s\033[0m\n" "$CRED_FILE"
echo ""
MOTD_SCRIPT

    chmod +x /etc/update-motd.d/50-street-app

    for f in /etc/update-motd.d/*; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "50-street-app" ] && continue
        chmod -x "$f" 2>/dev/null || true
    done

    log_success "MOTD configurado com sucesso."
}
