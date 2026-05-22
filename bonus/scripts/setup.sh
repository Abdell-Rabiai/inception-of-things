#!/bin/bash

# ============================================================
# Bonus Setup Script: K3d + Argo CD + GitLab
#
# This script extends Part 3 by adding a self-hosted GitLab
# instance inside the K3d cluster. Argo CD will watch the
# local GitLab repo instead of GitHub.
#
# Requirements: Docker, k3d, kubectl, helm installed on the host
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"

# ============================================================
# [1/8] Check prerequisites
# ============================================================
echo -e "${GREEN}[1/8] Checking prerequisites...${NC}"
docker info > /dev/null 2>&1 || { echo -e "${RED}Docker is not running. Start Docker first.${NC}"; exit 1; }
command -v k3d &> /dev/null    || { echo -e "${RED}k3d not found. Install it first.${NC}"; exit 1; }
command -v kubectl &> /dev/null || { echo -e "${RED}kubectl not found. Install it first.${NC}"; exit 1; }
command -v helm &> /dev/null    || { echo -e "${RED}helm not found. Install it first.${NC}"; exit 1; }
echo "All prerequisites are ready."

# ============================================================
# [2/8] Create K3d cluster
# ============================================================
echo -e "${GREEN}[2/8] Creating K3d cluster...${NC}"
k3d cluster delete iot-cluster 2>/dev/null || true

# Port mapping: 8888:80 → app access via the K3d load balancer
k3d cluster create iot-cluster \
  --port "8888:80@loadbalancer" \
  --wait

echo "Waiting for cluster nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
echo "Cluster is ready."

# ============================================================
# [3/8] Create namespaces
# ============================================================
echo -e "${GREEN}[3/8] Creating namespaces...${NC}"
kubectl create namespace argocd
kubectl create namespace dev
kubectl create namespace gitlab
echo "Namespaces argocd, dev, and gitlab created."

# ============================================================
# [4/8] Install Argo CD
# ============================================================
echo -e "${GREEN}[4/8] Installing Argo CD...${NC}"
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>&1 | grep -v "is invalid"

echo "Waiting for Argo CD pods to start (1-2 minutes)..."
sleep 10
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-server -n argocd --timeout=180s
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-repo-server -n argocd --timeout=180s
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-application-controller -n argocd --timeout=180s
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-redis -n argocd --timeout=180s
echo "Argo CD is ready."

# Make Argo CD accessible externally via NodePort
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'

# ============================================================
# [5/8] Install GitLab via Helm
# ============================================================
echo -e "${GREEN}[5/8] Installing GitLab via Helm (this takes 5-10 minutes)...${NC}"

# Add the official GitLab Helm chart repository
helm repo add gitlab https://charts.gitlab.io/
helm repo update

# Install GitLab using our minimal values file
# See confs/gitlab-values.yaml for what's disabled and why
helm upgrade --install gitlab gitlab/gitlab --version 9.11.4 \
  --namespace gitlab \
  --timeout 600s \
  -f "$CONFS_DIR/gitlab-values.yaml"

echo "Waiting for GitLab pods to start (this may take 5-10 minutes)..."

# Wait for the critical GitLab components one by one
echo "  Waiting for GitLab Webservice..."
kubectl wait --for=condition=Ready pods -l app=webservice -n gitlab --timeout=600s 2>/dev/null || {
  echo -e "${YELLOW}  Webservice not ready yet, continuing...${NC}"
}
echo "  Waiting for GitLab Gitaly..."
kubectl wait --for=condition=Ready pods -l app=gitaly -n gitlab --timeout=600s 2>/dev/null || {
  echo -e "${YELLOW}  Gitaly not ready yet, continuing...${NC}"
}
echo "  Waiting for GitLab Sidekiq..."
kubectl wait --for=condition=Ready pods -l app=sidekiq -n gitlab --timeout=600s 2>/dev/null || {
  echo -e "${YELLOW}  Sidekiq not ready yet, continuing...${NC}"
}

# GitLab needs extra time after pods report Ready for internal initialization
echo "  Giving GitLab 60 seconds to fully initialize..."
sleep 60

echo "GitLab installation complete."

# ============================================================
# [6/8] Expose GitLab and retrieve credentials
# ============================================================
echo -e "${GREEN}[6/8] Retrieving GitLab credentials...${NC}"

# The Helm chart auto-generates the root password and stores it in a Secret
GITLAB_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab -o jsonpath="{.data.password}" | base64 -d)

echo "GitLab root password retrieved."

# ============================================================
# [7/8] Configure GitLab repo and push manifests
# ============================================================
echo -e "${GREEN}[7/8] Setting up GitLab repository...${NC}"

# Port-forward GitLab's webservice so we can reach it from the host.
# The GitLab Helm chart's webservice listens on port 8181 (Workhorse).
kubectl port-forward svc/gitlab-webservice-default -n gitlab 8181:8181 &
PF_PID=$!
sleep 5

GITLAB_URL="http://localhost:8181"

# Wait until GitLab API is responsive
echo "Waiting for GitLab API to respond..."
RETRIES=30
for i in $(seq 1 $RETRIES); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "$GITLAB_URL/api/v4/version" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "200" ]; then
    echo "GitLab API is responding (HTTP $HTTP_CODE)."
    break
  fi
  if [ "$i" = "$RETRIES" ]; then
    echo -e "${RED}GitLab API did not respond after $RETRIES attempts.${NC}"
    echo "Debug: kubectl get pods -n gitlab"
    echo "Debug: kubectl logs -n gitlab -l app=webservice"
    kill $PF_PID 2>/dev/null || true
    exit 1
  fi
  echo "  Attempt $i/$RETRIES — HTTP $HTTP_CODE, retrying in 10s..."
  sleep 10
done

# Create a personal access token for the root user via the GitLab toolbox.
# The toolbox pod has Rails console access — the standard way to create
# tokens programmatically in GitLab.
echo "Creating API access token via toolbox..."

# Find the toolbox pod (name varies by Helm chart version)
TOOLBOX_POD=$(kubectl get pods -n gitlab -l app=toolbox \
  -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
if [ -z "$TOOLBOX_POD" ]; then
  TOOLBOX_POD=$(kubectl get pods -n gitlab -l app=task-runner \
    -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
fi

if [ -z "$TOOLBOX_POD" ]; then
  echo -e "${RED}Could not find GitLab toolbox/task-runner pod.${NC}"
  echo "Available pods in gitlab namespace:"
  kubectl get pods -n gitlab
  kill $PF_PID 2>/dev/null || true
  exit 1
fi

echo "  Using toolbox pod: $TOOLBOX_POD"

# The Rails runner creates a Personal Access Token with API + Git scopes
API_TOKEN=$(kubectl exec -n gitlab "$TOOLBOX_POD" -- \
  /srv/gitlab/bin/rails runner "
    token = User.find_by_username('root').personal_access_tokens.create!(
      name: 'argocd-token',
      scopes: ['api', 'read_repository', 'write_repository'],
      expires_at: 365.days.from_now
    )
    print token.token
  " 2>/dev/null)

if [ -z "$API_TOKEN" ]; then
  echo -e "${RED}Failed to create API token.${NC}"
  kill $PF_PID 2>/dev/null || true
  exit 1
fi

echo "  API token created successfully."

# Create a new project (repository)
# Subject requires: login of a group member in the repo name
echo "Creating GitLab repository..."
CREATE_RESULT=$(curl -s -X POST "$GITLAB_URL/api/v4/projects" \
  --header "PRIVATE-TOKEN: $API_TOKEN" \
  --data "name=arabiai-iot&visibility=public&initialize_with_readme=false")

PROJECT_ID=$(echo "$CREATE_RESULT" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
echo "  Project created (ID: $PROJECT_ID)"

# Push manifests to the new GitLab repository
echo "Pushing manifests to GitLab..."
WORK_DIR=$(mktemp -d)
cd "$WORK_DIR"

git config --global user.email "root@gitlab.local"
git config --global user.name "Administrator"
git init
git remote add origin "http://root:${API_TOKEN}@localhost:8181/root/arabiai-iot.git"

# Copy manifests from our confs directory
cp -r "$CONFS_DIR/manifests" .

git add .
git commit -m "Initial commit: wil-playground v1"
git branch -M main
git push -u origin main --force

cd "$SCRIPT_DIR"
rm -rf "$WORK_DIR"
echo "  Manifests pushed to local GitLab."

# Kill the port-forward (Argo CD uses internal DNS, not port-forward)
kill $PF_PID 2>/dev/null || true
wait $PF_PID 2>/dev/null || true

# ============================================================
# [8/8] Deploy Argo CD Application pointing to local GitLab
# ============================================================
echo -e "${GREEN}[8/8] Deploying Argo CD Application...${NC}"

# KEY CONCEPT: Kubernetes internal DNS
# Inside the cluster, any pod can reach any service using:
#   <service-name>.<namespace>.svc.cluster.local
# Argo CD (in argocd namespace) reaches GitLab (in gitlab namespace) at:
#   http://gitlab-webservice-default.gitlab.svc.cluster.local:8181
GITLAB_INTERNAL_URL="http://gitlab-webservice-default.gitlab.svc.cluster.local:8181"

# Apply the Argo CD Application manifest
cat <<ARGOAPP | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: wil-playground
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GITLAB_INTERNAL_URL}/root/arabiai-iot.git
    targetRevision: main
    path: manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
    syncOptions:
    - CreateNamespace=true
ARGOAPP

echo "Waiting for Argo CD to sync and deploy the application..."
sleep 30
kubectl wait --for=condition=Ready pods --all -n dev --timeout=120s 2>/dev/null || true

# ============================================================
# Save credentials and print access information
# ============================================================
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

cat > "$SCRIPT_DIR/../credentials.txt" << EOF
============================================
  Bonus: GitLab + Argo CD Credentials
============================================

--- GitLab ---
Internal URL:  ${GITLAB_INTERNAL_URL}
Port-forward:  kubectl port-forward svc/gitlab-webservice-default -n gitlab 8181:8181
Web UI:        http://localhost:8181
Username:      root
Password:      ${GITLAB_PASSWORD}
API Token:     ${API_TOKEN}
Repository:    root/arabiai-iot

--- Argo CD ---
Port-forward:  kubectl port-forward svc/argocd-server -n argocd 8080:443
Web UI:        https://localhost:8080
Username:      admin
Password:      ${ARGOCD_PASSWORD}

--- Application ---
Port-forward:  kubectl port-forward svc/wil-playground-svc -n dev 8888:8888
Test:          curl http://localhost:8888

--- Useful commands ---
  kubectl get ns
  kubectl get pods -n gitlab
  kubectl get pods -n argocd
  kubectl get pods -n dev
  kubectl get applications -n argocd

--- To switch from v1 to v2 ---
  1. Port-forward GitLab:
     kubectl port-forward svc/gitlab-webservice-default -n gitlab 8181:8181 &
  2. Clone the repo:
     git clone http://root:${API_TOKEN}@localhost:8181/root/arabiai-iot.git
  3. Edit manifests/deployment.yaml: change v1 to v2
  4. Commit and push:
     git add . && git commit -m "Update to v2" && git push
  5. Argo CD will auto-sync (or sync manually from the UI)
  6. Verify:
     kubectl port-forward svc/wil-playground-svc -n dev 8888:8888 &
     curl http://localhost:8888
============================================
EOF

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Bonus setup complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${YELLOW}Credentials saved to: bonus/credentials.txt${NC}"
echo ""
cat "$SCRIPT_DIR/../credentials.txt"