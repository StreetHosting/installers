# n8n Installer

This installer deploys n8n on VirtFusion VPS environments using Docker.

## Application Purpose
n8n is an extendable workflow automation tool that allows you to connect anything to everything via its open-source node-based approach.

## Installation Behavior
- Detects the operating system (Ubuntu/Debian supported).
- Installs Docker and Docker Compose if not already present.
- Configures a full n8n stack:
    - **n8n**: The main automation engine.
    - **PostgreSQL 16**: Used as the primary database for better performance and scalability.
    - **Task Runners (External)**: Executes Code nodes (JS/Python) in isolated containers for security.
- Sets up data persistence in `/opt/apps/n8n/n8n_data` and `/opt/apps/n8n/postgres_data`.
- Automatically retrieves the public IP for initial configuration.
- Configures `N8N_SECURE_COOKIE=false` to allow access via HTTP (useful for initial setup without SSL).

## Exposed Ports
- **5678**: The main n8n web interface and webhook port.

## Runtime Environment
- **Docker**: Official n8n, runners, and postgres container images.
- **Docker Compose**: Used for full stack orchestration and health-based dependencies.
- **Security**: Randomly generated passwords for PostgreSQL and secure tokens for Task Runners.

## Access Instructions
Once the provisioning script completes:
1. Access the n8n dashboard at `http://YOUR_SERVER_IP:5678`.
2. Follow the on-screen instructions to create your initial user account.

## Support
This installer is maintained as part of the StreetHosting VirtFusion Provisioner repository.
Stable Branch: production
Main Branch: development
