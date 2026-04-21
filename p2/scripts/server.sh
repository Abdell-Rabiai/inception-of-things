#!/bin/bash

# Update package manager and install curl
apt-get update -y
apt-get install -y curl

# Install K3s in server mode
# --write-kubeconfig-mode 644: makes kubeconfig readable by vagrant user
# --node-ip: advertise on the private network interface
# --flannel-iface: use the private network for pod traffic
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --write-kubeconfig-mode 644 \
  --node-ip 192.168.56.110 \
  --flannel-iface eth1" sh -

# Wait for K3s to be fully ready
echo "Waiting for K3s to start..."
while ! kubectl get nodes &>/dev/null; do
  sleep 2
done
echo "K3s server is ready."

# Wait for all system pods to be running before deploying apps
echo "Waiting for system pods..."
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=120s

# Apply all application configurations from the shared /vagrant/confs directory
# These YAML files define our three apps and the Ingress routing rules
echo "Deploying applications..."
kubectl apply -f /vagrant/confs/

echo "All applications deployed."