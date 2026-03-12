# n8n Installer

This installer deploys n8n on VirtFusion VPS environments using Docker.

## Application Purpose
n8n is an extendable workflow automation tool that allows you to connect anything to everything via its open-source node-based approach.

## Installation Behavior
- Detects the operating system (Ubuntu/Debian supported).
- Installs Docker and Docker Compose if not already present.
- Configures n8n to run within a Docker container.
- Sets up data persistence in `/opt/apps/n8n/n8n_data`.
- Automatically retrieves the public IP for initial configuration.

## Exposed Ports
- **5678**: The default n8n web interface and webhook port.

## Runtime Environment
- **Docker**: Official n8n container image.
- **Docker Compose**: Used for service orchestration and restart policies.

## Access Instructions
Once the provisioning script completes:
1. Access the n8n dashboard at `http://YOUR_SERVER_IP:5678`.
2. Follow the on-screen instructions to create your initial user account.

## Support
This installer is maintained as part of the StreetHosting VirtFusion Provisioner repository.
Stable Branch: production
Main Branch: development
