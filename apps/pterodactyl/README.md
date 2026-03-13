# Pterodactyl Panel Installer

Pterodactyl is a free, open-source game server management panel built with PHP 8, React, and Go. Designed with security in mind, Pterodactyl runs each game server in an isolated Docker container while providing a beautiful and intuitive UI to end users.

## Exposed Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 80   | TCP      | HTTP (Nginx Reverse Proxy) |
| 443  | TCP      | HTTPS (After SSL Setup) |
| 8080 | TCP      | Pterodactyl Panel (Internal Docker Port) |

## Installation Details

- **Database**: MariaDB 10.11 (Random Root Password generated)
- **Cache**: Redis 7
- **Reverse Proxy**: Nginx (Installed on host)
- **Docker Strategy**: Panel, Database, and Redis are all dockerized.

## Post-Installation Setup

This installer includes an interactive first-login script. When you first log in to your VPS via SSH as `root`, you will be prompted to:

1.  **Configure a Domain**: Choose whether to use a custom domain name.
2.  **DNS Pointing**: If you choose a domain, the script will provide the IP address for you to point your A record.
3.  **Automatic SSL**: The script will automatically generate a Let's Encrypt SSL certificate using `certbot`.
4.  **Automatic Nginx Configuration**: Nginx will be updated to use the new domain and SSL certificate.

## Initial Access

Until the SSL/Domain setup is complete, you can access the panel via:
`http://SERVER_IP`

**Initial Admin Credentials:**
- **Email**: `admin@streetworks.com.br`
- **Username**: `admin`
- **Password**: (Generated during installation - check the provisioner logs)

## Security Note

- All database passwords are randomly generated and stored in `/opt/apps/pterodactyl/docker-compose.yml`.
- The `APP_KEY` is also randomly generated and stored in the same file.
- It is highly recommended to change the admin password and email immediately after your first login.
