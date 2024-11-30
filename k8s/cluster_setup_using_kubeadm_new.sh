#!/bin/bash

kubeconfig_path=''

# Function to display help or unknown option error
function unknown_option() {
  echo -e "\nUnknown K8S node type: $1\n"; 
  echo "--------------------------------------------------------------------------"
  echo "    Preferred Ubuntu 20.04_LTS or above with below requirements"
  echo "------------------------------ Master setup ------------------------------"
  echo "    Minimum requirement - 2GB RAM & 2Core CPU" 
  echo "    k8s_install.sh master"
  echo "------------------------------ Worker setup ------------------------------"
  echo "    Minimum requirement - Any"
  echo "    k8s_install.sh worker"
  echo "--------------------------------------------------------------------------"
}

# Check if the machine is Linux and determine the distro (Ubuntu or RHEL)
UNAME=$(uname | tr "[:upper:]" "[:lower:]")

if [ "$UNAME" == "linux" ]; then
    # Check for Ubuntu or RHEL-based systems
    if [ -f /etc/lsb-release -o -d /etc/lsb-release.d ]; then
        kubeconfig_path='/home/ubuntu'
    elif [[ -f /etc/redhat-release ]]; then
        kubeconfig_path='/home/ec2-user'
    else 
        echo -e "Linux is not either Ubuntu nor RHEL...\n"; 
        unknown_option
        exit 1
    fi  
else 
    echo -e "Not a Linux platform...\n"; 
    unknown_option
    exit 1
fi

# Display help if requested
if [[ "$1" == "--help" || "$1" == "help" || "$1" == "-h" ]]; then
    unknown_option
    exit 0
fi

# Master or Worker node setup
if [[ "$1" == 'master' ]]; then 
    echo -e "\n-------------------------- K8S Master node setup --------------------------"
elif [[ "$1" == 'worker' ]]; then 
    echo -e "\n-------------------------- K8S Worker node setup --------------------------"
else 
    unknown_option $1
    exit 1
fi

# OS and base configuration
echo -e "\n-------------------------- Updating OS and Base configuration --------------------------\n"
sudo apt update
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
sudo tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
sudo tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system

# Install necessary packages for downloading
echo -e "\n-------------------------- APT transport for downloading pkgs via HTTPS --------------------------\n"
sudo apt-get install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates

# Enable the Docker repository and install Docker
echo -e "\n-------------------------- Enable the Docker repository --------------------------\n"
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt update
sudo apt install -y containerd.io

# Configure containerd
echo -e "\n-------------------------- Install container.io --------------------------\n"
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl stop containerd
sudo systemctl start containerd
sudo systemctl enable containerd

# Add Kubernetes APT repository
echo -e "\n-------------------------- Adding K8S packages to APT list --------------------------\n"
[[ -d "/etc/apt/keyrings" ]] || mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install kubelet, kubeadm, kubectl
echo -e "\n-------------------------- Install kubeadm, kubelet, kubectl and kubernetes-cni --------------------------\n"
sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo snap install kubectx --classic
sudo apt-mark hold kubelet kubeadm kubectl

# If it's the master node setup
if [[ "$1" == 'master' ]]; then 
    echo -e "\n-------------------------- Initiating kubeadm control-plane (master node) --------------------------\n"
    sudo kubeadm init --pod-network-cidr=192.168.0.0/16

    # Print join command for worker nodes
    echo "--------------------------------------------------------------------------"
    echo "       Save the above kubeadm join <token> command to run on worker node"
    echo "--------------------------------------------------------------------------"

    echo -e "\n-------------------------- Copy the join <token> command --------------------------\n"
    echo "    The join command must be executed on the worker node that we intend to add to the control-plane."
    echo "      1. Save the join command in a separate file for future use."
    echo "      2. If the join command is lost, regenerate it using the following command:"  
    echo "            kubeadm token create --print-join-command"
    echo -e "\n-----------------------------------------------------------------------------------\n"

    # Set kubeconfig for kubectl
    echo -e "\n-------------------------- Setting up Kubectl config --------------------------\n"
    sleep 4
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config 
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    [[ -f "$HOME/.kube/config" ]] || echo "     Kubeconfig copied to $HOME/.kube/config"

    # Install Calico CNI network plugin
    echo -e "\n-------------------------- Install Calico CNI --------------------------\n"
    kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml 

    # Wait for master node to become ready
    echo -e "\n-------------------------- Checking master node status ---------------------------\n"
    kubectl get nodes
    echo -e "\nWaiting for control-plane (master node) to get Ready ...........\n"
    sleep 15
    kubectl get nodes
    echo -e "\nIf node is still not in Ready state, try installing Calico Typha CNI:"
    echo "    1. kubectl apply -f https://docs.projectcalico.org/manifests/calico-typha.yaml"
    echo "    2. kubectl get nodes"
    echo -e "\n-----------------------------------------------------------------------------------"
fi  

# Worker node setup instructions
if [[ "$1" == 'worker' ]]; then 
    echo "------------------------------------------------------------------------------------"
    echo "    1. Switch to root user: sudo su -"
    echo "    2. Allow incoming traffic to port 6443 in control-plane (master node)"
    echo "    3. Run the kubeadm join <TOKEN> command obtained from master node"
    echo "    4. Run 'kubectl get nodes' on the control-plane to verify the worker node joined the cluster."
    echo "------------------------------------------------------------------------------------"
fi
