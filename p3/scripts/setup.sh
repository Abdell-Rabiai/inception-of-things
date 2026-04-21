#!/bin/bash

# ============================================================
# Part 3 Setup Script: K3d + Argo CD
# Installs all tools locally in /goinfre/ (no sudo required)
# Creates a K3d cluster, installs Argo CD, and configures
# it to watch a GitHub repository for automatic deployments.
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Local bin directory in /goinfre/ (no sudo needed, no quota)
LOCAL_BIN="/goinfre/$USER/.local/bin"
mkdir -p "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$PATH"

echo -e "${GREEN}[1/6] Installing K3d...${NC}"
# K3d runs K3s inside Docker containers instead of VMs
# Much faster to create/destroy clusters (seconds vs minutes)
if ! command -v k3d &> /dev/null; then
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | K3D_INSTALL_DIR="$LOCAL_BIN" USE_SUDO=false bash
else
  echo "K3d already installed: $(k3d version)"
fi

echo -e "${GREEN}[2/6] Installing kubectl...${NC}"
# kubectl is the CLI for talking to any Kubernetes cluster
if ! command -v kubectl &> /dev/null; then
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
  chmod +x kubectl
  mv kubectl "$LOCAL_BIN/"
else
  echo "kubectl already installed"
fi

echo -e "${GREEN}[3/6] Creating K3d cluster...${NC}"
# Delete existing cluster if it exists (clean slate)
k3d cluster delete iot-cluster 2>/dev/null || true

# Create a new K3d cluster
# --port "8888:8888@loadbalancer": maps port 8888 on your machine
#   to port 8888 inside the cluster, so you can curl localhost:8888
# --port "8080:80@loadbalancer": maps port 8080 for Argo CD web UI
# --agents 0: no separate agent nodes (server handles everything)
# --wait: block until the cluster is fully ready
k3d cluster create iot-cluster \
  --port "8888:8888@loadbalancer" \
  --port "8080:80@loadbalancer" \
  --wait

# Verify the cluster is running
echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
echo "Cluster is ready."

echo -e "${GREEN}[4/6] Creating namespaces...${NC}"
# argocd: where Argo CD's own components run
# dev: where our application will be deployed
kubectl create namespace argocd
kubectl create namespace dev

echo -e "${GREEN}[5/6] Installing Argo CD...${NC}"
# Install Argo CD into the argocd namespace
# This applies the official manifests which create:
# - argocd-server (web UI + API)
# - argocd-repo-server (clones and caches Git repos)
# - argocd-application-controller (watches repos, syncs state)
# - argocd-redis (cache)
# - argocd-dex-server (authentication)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for all Argo CD pods to be ready
echo "Waiting for Argo CD pods to start (this may take 1-2 minutes)..."
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=180s
echo "Argo CD is ready."

# Change the argocd-server service to NodePort so we can access the UI
# By default it's ClusterIP (internal only)
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'

echo -e "${GREEN}[6/6] Deploying Argo CD Application...${NC}"
# Apply the Argo CD Application resource
# This tells Argo CD: "watch this GitHub repo and deploy to the dev namespace"
kubectl apply -f /goinfre/$USER/iot/p3/confs/argocd-app.yaml

# ============================================================
# Print access information
# ============================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

# Get the Argo CD admin password
# Argo CD generates a random password stored as a Kubernetes secret
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo -e "${YELLOW}Argo CD Web UI:${NC}"
echo "  URL: https://localhost:8080 (accept the self-signed certificate)"
echo "  Username: admin"
echo "  Password: $ARGOCD_PASSWORD"
echo ""
echo -e "${YELLOW}Application:${NC}"
echo "  curl http://localhost:8888"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  kubectl get pods -n argocd     # Check Argo CD pods"
echo "  kubectl get pods -n dev        # Check app pods"
echo "  kubectl get ns                 # List namespaces"