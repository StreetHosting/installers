# Uptime Kuma

Uptime Kuma is a fancy self-hosted monitoring tool that you can use to monitor your services and websites.

## Application Details

* **Service**: Uptime Kuma
* **Default Port**: 3001
* **Image**: louislam/uptime-kuma:1

## Installation Behavior

* Installs Docker if not already present.
* Creates a directory at `/opt/apps/uptime-kuma`.
* Persists data in `/opt/apps/uptime-kuma/data`.
* Runs as a Docker container using Docker Compose.

## Access Instructions

After provisioning, you can access Uptime Kuma at:

`http://SERVER_IP:3001`

You will be prompted to create your initial administrator account upon first access.

## Maintenance

To view logs:
```bash
cd /opt/apps/uptime-kuma
docker compose logs -f
```

To restart the service:
```bash
cd /opt/apps/uptime-kuma
docker compose restart
```
