#!/bin/bash

# ============================================================
# Part 3 Setup Script: K3d + Argo CD
# Creates a K3d cluster, installs Argo CD, and configures
# it to watch a GitHub repository for automatic deployments.
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[1/5] Checking prerequisites...${NC}"
docker info > /dev/null 2>&1 || { echo "Docker is not running. Start Docker first."; exit 1; }
command -v k3d &> /dev/null || { echo "K3d not found. Install it first."; exit 1; }
command -v kubectl &> /dev/null || { echo "kubectl not found. Install it first."; exit 1; }
echo "Docker, K3d, and kubectl are ready."

echo -e "${GREEN}[2/5] Creating K3d cluster...${NC}"
k3d cluster delete iot-cluster 2>/dev/null || true

k3d cluster create iot-cluster \
  --port "8888:80@loadbalancer" \
  --port "8080:80@loadbalancer" \
  --wait

echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
echo "Cluster is ready."

echo -e "${GREEN}[3/5] Creating namespaces...${NC}"
kubectl create namespace argocd
kubectl create namespace dev

echo -e "${GREEN}[4/5] Installing Argo CD...${NC}"
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for Argo CD pods to start (this may take 1-2 minutes)..."
sleep 10
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-server -n argocd --timeout=180s
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-repo-server -n argocd --timeout=180s
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-application-controller -n argocd --timeout=180s
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-redis -n argocd --timeout=180s
echo "Argo CD is ready."

kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'

echo -e "${GREEN}[5/5] Deploying Argo CD Application...${NC}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
kubectl apply -f "$SCRIPT_DIR/../confs/argocd-app.yaml"

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo -e "${YELLOW}Argo CD Web UI:${NC}"
echo "  URL: https://localhost:8080"
echo "  Username: admin"
echo "  Password: $ARGOCD_PASSWORD"
echo ""
echo -e "${YELLOW}Application:${NC}"
echo "  curl http://localhost:8888"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  kubectl get pods -n argocd"
echo "  kubectl get pods -n dev"
echo "  kubectl get ns"