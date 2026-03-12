# Docker installation utility for VirtFusion Provisioners

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo "[INFO] Docker is already installed"
        return 0
    fi

    echo "[INFO] Installing Docker..."
    
    # Update and install dependencies
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(source /etc/os-release && echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add the repository to Apt sources
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(source /etc/os-release && echo "$ID") \
      $(source /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    DEBIAN_FRONTEND=noninteractive apt-get update -y

    # Install Docker packages
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    if command -v docker >/dev/null 2>&1; then
        echo "[SUCCESS] Docker installed successfully"
    else
        echo "[ERROR] Docker installation failed"
        exit 1
    fi
}
