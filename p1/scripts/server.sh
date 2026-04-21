#!/bin/bash

# Update package manager and install curl (needed to download K3s)
apt-get update -y
apt-get install -y curl

# Install K3s in server mode
# --write-kubeconfig-mode 644: makes the kubeconfig readable by all users (not just root)
# --node-ip: tells K3s to advertise on our private network IP, not the NAT interface
# --flannel-iface: tells the CNI network plugin to use the private network interface
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --write-kubeconfig-mode 644 \
  --node-ip 192.168.56.110 \
  --flannel-iface eth1" sh -

# Wait for K3s to be ready before proceeding
echo "Waiting for K3s to start..."
while ! kubectl get nodes &>/dev/null; do
  sleep 2
done
echo "K3s server is ready."

# Copy the node token to a shared location so the agent VM can access it
# Vagrant syncs /vagrant on each VM to the project directory on the host
# This means writing to /vagrant/scripts/ makes the file appear in p1/scripts/ on the host
# and the agent VM can read it from its own /vagrant mount
cp /var/lib/rancher/k3s/server/node-token /vagrant/scripts/node-token
echo "Node token saved to /vagrant/scripts/node-token"