#!/bin/bash

# This script automates the setup of Docker, NGINX Proxy Manager, and Portainer on a Debian-based system.
# It installs Docker, sets up user permissions, creates Docker networks, and launches Docker Compose stacks.

set -e

export DEBIAN_FRONTEND=noninteractive  # Prevents TTY prompts from apt

# --- Parse Arguments ---
for i in "$@"; do
	case $i in
		--hostname=*)
			HOSTNAME="${i#*=}"
			;;
		--pip=*)
			PUBLICIP="${i#*=}"
			;;
   		--username=*)
     			TARGETUSER="${i#*=}"
			;;
		*)
			echo "Warning: Unknown option $i"
			;;
	esac
done

echo "Server Hostname (local): $HOSTNAME"
echo "Public IP Address (for access & SSL): $PUBLICIP"
echo "The Local User name is: $TARGETUSER"

# --- Prerequisites ---
echo "Installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# --- Docker GPG and Repo Setup ---
echo "Setting up Docker GPG key and repository..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# --- Install Docker ---
echo "Installing Docker Engine and Compose plugin..."
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# --- Add User to Docker Group ---
echo "Adding user '$TARGETUSER' to the docker group..."
sudo usermod -aG docker "$TARGETUSER"

# --- Docker Compose Folder Setup ---
echo "Setting up Docker Compose directories..."
BASE_COMPOSE_DIR="/opt/docker-compose"
sudo mkdir -p "$BASE_COMPOSE_DIR/nginx-manager"
sudo mkdir -p "$BASE_COMPOSE_DIR/portainer"

# --- Download Docker Compose Files ---
cd "$BASE_COMPOSE_DIR/nginx-manager"
sudo wget -q https://raw.githubusercontent.com/VivaLaDokky/public/refs/heads/main/docker-compose/nginx-manager/docker-compose.yml

cd "$BASE_COMPOSE_DIR/portainer"
sudo wget -q https://raw.githubusercontent.com/VivaLaDokky/public/refs/heads/main/docker-compose/portainer/docker-compose.yml

# --- Create Docker Network ---
echo "Creating shared Docker network: proxy_network"
sudo docker network create proxy_network || echo "Network 'proxy_network' already exists."

# --- Launch Containers ---
echo "Launching NGINX Proxy Manager and Portainer..."
sudo docker compose -f "$BASE_COMPOSE_DIR/nginx-manager/docker-compose.yml" up -d
sudo docker compose -f "$BASE_COMPOSE_DIR/portainer/docker-compose.yml" up -d

# Get Portainer container IP
PORTAINER_CONTAINER=$(sudo docker ps --filter "name=^/portainer$" --format "{{.ID}}")
PORTAINER_IP=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PORTAINER_CONTAINER")

# Output
echo "🖥️  Portainer container internal IP: $PORTAINER_IP, add this in NGINX"

# --- Done ---
echo
echo "✅ Script complete."
echo "➡️ NGINX Proxy Manager should be reachable at: http://$PUBLICIP:81 or DNS Label"
echo "🛠️ Portainer UI is not accessible before you forward $PORTAINER_IP and forward port 9000 in NGINX"
echo "👤 Default credentials for NGINX: username 'admin@example.com', password 'changeme'"
echo "🔄 Please log out and back in (or reboot) for Docker permissions to take effect."
