#!/bin/bash
 
# Set environment variables
KUBERNETES_VERSION="1.23/stable"
CHANNEL="1.8/stable"
USERNAME="admin"
PASSWORD="admin"
DEX_PUBLIC_URL="http://10.64.140.43.nip.io"
 
# Function to check the exit status of a command and print a message
check_status() {
    if [ $? -eq 0 ]; then
        echo "$1: SUCCESS"
    else
        echo "$1: FAILED"
        exit 1
    fi
}
 
# Function to retry a command until it succeeds or reaches the max retry limit
retry() {
    local retries=$1
    shift
    local delay=$1
    shift
    local cmd="$@"
    for ((i=1; i<=retries; i++)); do
        $cmd && break || {
            echo "Attempt $i/$retries failed. Retrying in $delay seconds..."
            sleep $delay
        }
    done
 
    if [ $i -gt $retries ]; then
        echo "Command failed after $retries attempts."
        exit 1
    fi
}
 
# Install Juju, Juju-wait, and Charmcraft using snap
for snap in juju juju-wait charmcraft; do 
    sudo snap install $snap --classic
    check_status "Installing $snap"
done
 
# Install MicroK8s
sudo snap install microk8s --classic --channel=${KUBERNETES_VERSION}
check_status "Installing MicroK8s"
 
# Refresh Charmcraft to the latest candidate version
sudo snap refresh charmcraft --channel latest/candidate
check_status "Refreshing Charmcraft to the latest candidate version"
 
# Add the user 'ubuntu' to the microk8s group
sudo usermod -a -G microk8s ubuntu
check_status "Adding 'ubuntu' to the microk8s group"
 
 
# Enable essential Kubernetes services (DNS, Storage, and MetalLB)
microk8s enable dns storage metallb:"10.64.140.43-10.64.140.49,192.168.0.105-192.168.0.111"
check_status "Enabling Kubernetes services (DNS, Storage, and MetalLB)"
 
# Wait for CoreDNS and Storage Provisioner to be available with retry mechanism
retry 10 30 microk8s.kubectl wait --for=condition=available -n kube-system deployment/coredns deployment/hostpath-provisioner
check_status "Waiting for CoreDNS and Storage Provisioner availability"
 
# Check rollout status of the Calico daemonset
microk8s.kubectl -n kube-system rollout status ds/calico-node
check_status "Checking rollout status of the Calico daemonset"
 
# Create directory for Kubernetes credentials and extract MicroK8s config
sudo mkdir -p /var/snap/juju/current/microk8s/credentials
check_status "Creating directory for Kubernetes credentials"
microk8s config | sudo tee /var/snap/juju/current/microk8s/credentials/client.config
check_status "Extracting MicroK8s config"
sudo chown -R $USER:$USER /var/snap/juju/current/microk8s/credentials
check_status "Changing ownership of the credentials directory"
 
# create the Juju directory needed for bootstrap
mkdir -p ~/.local/share/juju
check_status "Creating Juju home directory"
 
# Bootstrap Juju with a MicroK8s cloud and set up the controller
juju bootstrap microk8s uk8s-controller
check_status "Bootstrapping Juju with MicroK8s"
 
# Add a Juju model for Kubeflow
juju add-model kubeflow
check_status "Adding Juju model 'kubeflow'"
 
# Deploy Kubeflow using Juju charms
juju deploy kubeflow --channel=${CHANNEL} --trust
check_status "Deploying Kubeflow"
 
# Configure Dex Auth and OIDC Gatekeeper
juju config dex-auth public-url=${DEX_PUBLIC_URL}
check_status "Configuring Dex Auth public URL"
juju config oidc-gatekeeper public-url=${DEX_PUBLIC_URL}
check_status "Configuring OIDC Gatekeeper public URL"
juju config dex-auth static-username=${USERNAME}
check_status "Setting Dex Auth username"
juju config dex-auth static-password=${PASSWORD}
check_status "Setting Dex Auth password"
 
# Update package list and install nginx
sudo apt update
check_status "Updating package list"
sudo apt install -y nginx
check_status "Installing nginx"

# Run the command to edit the nginx config file
sudo bash -c 'cat > /etc/nginx/sites-available/default' <<EOF
server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://10.64.140.43.nip.io;
        proxy_http_version 1.1;  # Ensure it uses HTTP/1.1
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "upgrade";  # Necessary for WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
    }
}
EOF

sudo ufw disable
# Restart nginx and print success message
sudo systemctl restart nginx 
echo "Restarting nginx"
sleep 200
echo "Restart successful"