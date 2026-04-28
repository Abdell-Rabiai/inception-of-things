#!/bin/bash

# ============================================================
# Prerequisites Installation Script
#
# Installs all tools required for the Bonus part:
#   - Docker: container runtime (K3d runs K3s nodes as containers)
#   - k3d:    creates K3s clusters inside Docker containers
#   - kubectl: CLI to interact with Kubernetes clusters
#   - helm:   package manager for Kubernetes (installs GitLab)
#
# Run this BEFORE setup.sh on a fresh Ubuntu 22.04+ machine.
# ============================================================

set -e

GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}[1/4] Installing Docker...${NC}"
if command -v docker &> /dev/null; then
  echo "Docker is already installed: $(docker --version)"
else
  # Install Docker using the official convenience script
  curl -fsSL https://get.docker.com | sh
  # Allow current user to run docker without sudo
  sudo usermod -aG docker "$USER"
  echo "Docker installed: $(docker --version)"
  echo "NOTE: You may need to log out and back in for group changes to take effect."
fi

echo -e "${GREEN}[2/4] Installing kubectl...${NC}"
if command -v kubectl &> /dev/null; then
  echo "kubectl is already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
else
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl
  echo "kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

echo -e "${GREEN}[3/4] Installing k3d...${NC}"
if command -v k3d &> /dev/null; then
  echo "k3d is already installed: $(k3d version)"
else
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
  echo "k3d installed: $(k3d version)"
fi

echo -e "${GREEN}[4/4] Installing Helm...${NC}"
if command -v helm &> /dev/null; then
  echo "Helm is already installed: $(helm version --short)"
else
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  echo "Helm installed: $(helm version --short)"
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  All prerequisites installed!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "You can now run: bash scripts/setup.sh"