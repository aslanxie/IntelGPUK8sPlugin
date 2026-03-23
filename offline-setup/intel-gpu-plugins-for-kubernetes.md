# Intel GPU Plugins for Kubernetes (Air-Gapped Setup)

This guide walks you through setting up a Kubernetes cluster with Intel GPU device plugins in an **air-gapped (offline) environment**. You will prepare all required binaries, images, and manifests on an internet-connected machine, transfer them to the target servers, and then deploy the cluster.

## Prerequisites

**Internet-connected machine:**
- Docker installed (for pulling and saving images)
- `curl`, `wget` installed

**Target server(s):**
- Linux amd64 (e.g., Ubuntu 22.04+)
- `containerd` installed and running as the container runtime
- Intel GPU driver installed (xe) and GPU visible via `ls /dev/dri/`

**Working directory on target server(s):**

The setup script expects the following layout (created by `prepare_online.sh`):

```
intel_gpu_k8s/
├── binaries/
│   ├── kubectl
│   ├── opt/cni/bin/...
│   └── usr/
│       ├── local/bin/{kubeadm,kubelet,crictl}
│       └── lib/systemd/system/kubelet.service{,.d/10-kubeadm.conf}
├── images/
│   └── k8s_bundle.tar.gz
├── manifests/
│   ├── kube-flannel.yml
│   ├── nfd.yaml
│   ├── nfd-gpu-rules.yaml
│   └── gpu-plugin.yaml
├── setup_control_node.sh
├── setup_node_base.sh
└── setup_worker_node.sh
```

---

## Step 1: Prepare on Internet-Connected Machine

> **Automated option:** You can run the [`prepare_online.sh`](prepare_online.sh) script to execute all sub-steps below automatically:
> ```bash
> # Uses ./intel_gpu_k8s/ as the staging directory by default
> chmod +x prepare_online.sh
> ./prepare_online.sh
>
> # Or specify a custom staging directory
> STAGING_DIR=/path/to/staging ./prepare_online.sh
> ```
> If you prefer to run each step manually, follow the sub-steps below.

### 1.1 Install kustomize

```bash
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
```

### 1.2 Download Kubernetes manifests

```bash
mkdir -p manifests

echo "=== Downloading NFD base ==="
./kustomize build 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd?ref=v0.35.0' > manifests/nfd.yaml

echo "=== Downloading GPU NodeFeatureRules ==="
./kustomize build 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd/overlays/node-feature-rules?ref=v0.35.0' > manifests/nfd-gpu-rules.yaml

echo "=== Downloading GPU plugin (NFD-labeled nodes overlay) ==="
./kustomize build 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/gpu_plugin/overlays/nfd_labeled_nodes?ref=v0.35.0' > manifests/gpu-plugin.yaml

echo "=== Downloading Flannel CNI manifest ==="
wget -O manifests/kube-flannel.yml https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

### 1.3 Pull container images

```bash
# Kubernetes core components
docker pull registry.k8s.io/kube-apiserver:v1.35.2
docker pull registry.k8s.io/kube-proxy:v1.35.2
docker pull registry.k8s.io/kube-scheduler:v1.35.2
docker pull registry.k8s.io/kube-controller-manager:v1.35.2
docker pull registry.k8s.io/etcd:3.6.6-0
docker pull registry.k8s.io/coredns/coredns:v1.13.1
docker pull registry.k8s.io/pause:3.10.1

# Flannel CNI
docker pull docker.io/flannel/flannel:v0.28.1
docker pull ghcr.io/flannel-io/flannel-cni-plugin:v1.9.0-flannel1

# NFD (Node Feature Discovery)
docker pull registry.k8s.io/nfd/node-feature-discovery:v0.18.3

# Intel GPU plugin
docker pull intel/intel-gpu-plugin:0.35.0
docker pull intel/intel-gpu-levelzero:0.35.0
```

### 1.4 Save all images to a single archive

```bash
mkdir -p images

docker save \
  registry.k8s.io/kube-apiserver:v1.35.2 \
  registry.k8s.io/kube-controller-manager:v1.35.2 \
  registry.k8s.io/kube-scheduler:v1.35.2 \
  registry.k8s.io/kube-proxy:v1.35.2 \
  registry.k8s.io/etcd:3.6.6-0 \
  registry.k8s.io/coredns/coredns:v1.13.1 \
  registry.k8s.io/pause:3.10.1 \
  docker.io/flannel/flannel:v0.28.1 \
  ghcr.io/flannel-io/flannel-cni-plugin:v1.9.0-flannel1 \
  registry.k8s.io/nfd/node-feature-discovery:v0.18.3 \
  intel/intel-gpu-plugin:0.35.0 \
  intel/intel-gpu-levelzero:0.35.0 \
  | gzip > images/k8s_bundle.tar.gz
```

### 1.5 Download Kubernetes binaries (without package manager)

```bash
export ARCH="amd64"

# --- CNI plugins ---
export CNI_PLUGINS_VERSION="v1.3.0"
mkdir -p binaries/opt/cni/bin
curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz" \
  | tar -C binaries/opt/cni/bin -xz

# --- crictl ---
mkdir -p binaries/usr/local/bin
export CRICTL_VERSION="v1.31.0"
curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" \
  | tar -C binaries/usr/local/bin -xz

# --- kubeadm & kubelet ---
export RELEASE="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
cd binaries/usr/local/bin
curl -L --remote-name-all https://dl.k8s.io/release/${RELEASE}/bin/linux/${ARCH}/{kubeadm,kubelet}
chmod +x kubeadm kubelet
cd -

# --- kubelet systemd service files ---
export RELEASE_VERSION="v0.16.2"
mkdir -p binaries/usr/lib/systemd/system/kubelet.service.d

curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/krel/templates/latest/kubelet/kubelet.service" \
  | sed "s:/usr/bin:/usr/local/bin:g" \
  | tee binaries/usr/lib/systemd/system/kubelet.service

curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf" \
  | sed "s:/usr/bin:/usr/local/bin:g" \
  | tee binaries/usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf

# --- kubectl ---
curl -LO "https://dl.k8s.io/release/${RELEASE}/bin/linux/${ARCH}/kubectl"
mv kubectl binaries/kubectl
```

### 1.6 Transfer files to target server

Copy the staging directory to the target server(s). Replace `<TARGET_USER>` and `<TARGET_HOST>` with your actual values.

```bash
# Transfer the entire staging directory to target server
scp -r binaries images manifests setup_control_node.sh setup_node_base.sh setup_worker_node.sh <TARGET_USER>@<TARGET_HOST>:/home/gta/workspace/intel_gpu_k8s/
```

---

## Step 2: Setup Control Node

Run the following on the **control plane node**. All commands assume you are in the working directory:

```bash
cd /home/gta/workspace/intel_gpu_k8s
```

> **Automated option:** You can run the [`setup_control_node.sh`](setup_control_node.sh) script to execute all sub-steps below automatically:
> ```bash
> chmod +x setup_control_node.sh setup_node_base.sh
> ./setup_control_node.sh
> ```
> The script expects the `binaries/`, `images/`, and `manifests/` directories in the current working directory.
>
> If you prefer to run each step manually, follow the sub-steps below.

### 2.1 Disable swap and configure kernel

```bash
# Disable swap (required by kubelet)
sudo swapoff -a

# Load br_netfilter module
sudo modprobe br_netfilter

# Verify it's loaded
lsmod | grep br_netfilter

# Persist after reboot
echo "br_netfilter" | sudo tee /etc/modules-load.d/k8s.conf

# Enable bridge netfilter and IP forwarding
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply the changes
sudo sysctl --system
```

### 2.2 Install CNI plugins

```bash
sudo mkdir -p /opt/cni/bin
sudo cp ./binaries/opt/cni/bin/* /opt/cni/bin/
```

### 2.3 Install kubeadm, kubelet, crictl

```bash
sudo cp ./binaries/usr/local/bin/{kubeadm,kubelet,crictl} /usr/local/bin/
sudo chmod +x /usr/local/bin/{kubeadm,kubelet,crictl}
```

### 2.4 Install kubectl

```bash
sudo install -o root -g root -m 0755 ./binaries/kubectl /usr/local/bin/kubectl
```

### 2.5 Install kubelet systemd service

```bash
sudo cp ./binaries/usr/lib/systemd/system/kubelet.service /usr/lib/systemd/system/kubelet.service
sudo mkdir -p /usr/lib/systemd/system/kubelet.service.d
sudo cp ./binaries/usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf \
  /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf

sudo systemctl daemon-reload
sudo systemctl enable kubelet
```

### 2.6 Load container images

```bash
zcat ./images/k8s_bundle.tar.gz | sudo ctr -n k8s.io images import -
```

### 2.7 Re-tag Flannel image

The Flannel manifest references `ghcr.io/flannel-io/flannel:v0.28.1`, but the pulled image uses the `docker.io` prefix. Re-tag it so containerd can resolve it:

```bash
sudo ctr -n k8s.io images tag docker.io/flannel/flannel:v0.28.1 ghcr.io/flannel-io/flannel:v0.28.1
```

### 2.8 Verify images are loaded

```bash
sudo ctr -n k8s.io images ls
```

### 2.9 Configure containerd for SystemdCgroup

Ensure containerd is configured to use the systemd cgroup driver and the correct pause image:

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo sed -i 's|sandbox_image = "registry.k8s.io/pause:3.8"|sandbox_image = "registry.k8s.io/pause:3.10.1"|' /etc/containerd/config.toml
sudo systemctl restart containerd
```

### 2.10 Initialize the cluster with kubeadm

```bash
sudo kubeadm init --kubernetes-version=v1.35.2 --pod-network-cidr=10.244.0.0/16
```

> **Important:** The `--pod-network-cidr=10.244.0.0/16` is required by Flannel. Save the `kubeadm join` command printed at the end — you will need it for worker nodes.

### 2.11 Configure kubectl for your user

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 2.12 Remove control-plane taint (single-node cluster)

Allow workloads to schedule on the control plane node:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### 2.13 Deploy Flannel CNI

```bash
kubectl apply -f ./manifests/kube-flannel.yml
```

Wait for the node to become `Ready`:

```bash
kubectl get nodes -w
```

### 2.14 Deploy Node Feature Discovery (NFD)

NFD detects hardware features (including Intel GPUs) and labels nodes accordingly.

```bash
kubectl apply -f ./manifests/nfd.yaml
```

Wait for NFD pods to be running:

```bash
kubectl get pods -n node-feature-discovery -w
```

### 2.15 Deploy GPU Node Feature Rules

```bash
kubectl apply -f ./manifests/nfd-gpu-rules.yaml
```

### 2.16 Deploy Intel GPU Device Plugin

```bash
kubectl apply -f ./manifests/gpu-plugin.yaml
```

Wait for the GPU plugin pods to be running:

```bash
kubectl get pods -n intel-gpu-plugin -w
```

### 2.17 Verify Intel GPU Plugin

Check that GPU resources are registered:

```bash
kubectl get nodes -o json | jq '.items[].status.allocatable' | grep gpu
```

You should see `gpu.intel.com/xe` with a count matching your available GPUs.

Run a test pod requesting GPU:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  containers:
  - name: gpu-test
    image: intel/intel-gpu-plugin:0.35.0
    command: ["sleep", "infinity"]
    resources:
      limits:
        gpu.intel.com/xe: 1
      requests:
        gpu.intel.com/xe: 1
EOF
```

Check that the pod is running and has access to the GPU:

```bash
kubectl get pod gpu-test
kubectl exec gpu-test -- ls /dev/dri/
```

Clean up the test pod:

```bash
kubectl delete pod gpu-test
```

---

## Step 3: Add New Worker Nodes

To add a worker node, first perform the node setup (Steps 2.1–2.9) on the new machine, then join it to the cluster.

### 3.1 Setup the worker node

Transfer the `binaries/`, `images/`, and `manifests/` directories to the worker node and run the setup script:

```bash
# On the internet-connected machine or control node, transfer files to the worker
scp -r binaries images manifests setup_worker_node.sh setup_node_base.sh <TARGET_USER>@<WORKER_HOST>:/home/gta/workspace/intel_gpu_k8s/
```

On the **worker node**:

```bash
cd /home/gta/workspace/intel_gpu_k8s
chmod +x setup_worker_node.sh setup_node_base.sh
./setup_worker_node.sh
```

The [`setup_worker_node.sh`](setup_worker_node.sh) script performs Steps 2.1–2.9 (swap/kernel, install binaries, load images, configure containerd) and prints the next steps for joining the cluster.

### 3.2 Get the join command (on the control node)

If the original join token has expired, generate a new one on the **control plane node**:

```bash
kubeadm token create --print-join-command
```

### 3.3 Join the cluster (on the worker node)

Run the join command output from the previous step on the **worker node**:

```bash
sudo kubeadm join <CONTROL_PLANE_IP>:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>
```

### 3.4 Verify the worker node (on the control node)

```bash
kubectl get nodes
kubectl get nodes --show-labels
```

The new worker node should appear and become `Ready` shortly. And label,like```device-id.0300-e211```, means GPU is detected on the node.
```
gta@DUT6053BMGFRD:~$ kubectl get nodes
NAME            STATUS   ROLES           AGE     VERSION
dut6053bmgfrd   Ready    control-plane   3m43s   v1.35.2
dut6332bmgfrd   Ready    <none>          2m33s   v1.35.2
gta@DUT6053BMGFRD:~$ kubectl get nodes --show-labels
NAME            STATUS   ROLES           AGE     VERSION   LABELS
dut6053bmgfrd   Ready    control-plane   3m46s   v1.35.2   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,gpu.intel.com/device-id.0300-e212.count=1,gpu.intel.com/device-id.0300-e212.present=true,intel.feature.node.kubernetes.io/gpu=true,kubernetes.io/arch=amd64,kubernetes.io/hostname=dut6053bmgfrd,kubernetes.io/os=linux,node-role.kubernetes.io/control-plane=,node.kubernetes.io/exclude-from-external-load-balancers=
dut6332bmgfrd   Ready    <none>          2m36s   v1.35.2   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,gpu.intel.com/device-id.0300-e211.count=1,gpu.intel.com/device-id.0300-e211.present=true,intel.feature.node.kubernetes.io/gpu=true,kubernetes.io/arch=amd64,kubernetes.io/hostname=dut6332bmgfrd,kubernetes.io/os=linux
```


