#!/usr/bin/env bash
#
# setup_node_base.sh — Common node setup (Steps 2.1–2.9)
#
# Shared by setup_control_node.sh and setup_worker_node.sh.
# This script is sourced, not executed directly.
#
# Required variables (set by the caller before sourcing):
#   BASE_DIR, BINARIES_DIR, IMAGES_DIR, MANIFESTS_DIR
#
# Required functions (defined by the caller before sourcing):
#   info, ok, warn, fail, check_exit

# ── Pre-flight checks ───────────────────────────────────────────────
info "Pre-flight checks..."

for dir in "${BINARIES_DIR}" "${IMAGES_DIR}" "${MANIFESTS_DIR}"; do
  if [ ! -d "${dir}" ]; then
    fail "Required directory not found: ${dir}"
  fi
done

for f in "${IMAGES_DIR}/k8s_bundle.tar.gz" \
         "${MANIFESTS_DIR}/kube-flannel.yml" \
         "${MANIFESTS_DIR}/nfd.yaml" \
         "${MANIFESTS_DIR}/nfd-gpu-rules.yaml" \
         "${MANIFESTS_DIR}/gpu-plugin.yaml" \
         "${BINARIES_DIR}/usr/local/bin/kubeadm" \
         "${BINARIES_DIR}/usr/local/bin/kubelet" \
         "${BINARIES_DIR}/usr/local/bin/crictl" \
         "${BINARIES_DIR}/kubectl" \
         "${BINARIES_DIR}/usr/lib/systemd/system/kubelet.service" \
         "${BINARIES_DIR}/usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf"; do
  if [ ! -f "${f}" ]; then
    fail "Required file not found: ${f}"
  fi
done

check_exit

if ! systemctl is-active --quiet containerd; then
  fail "containerd is not running. Start it first: systemctl start containerd"
  check_exit
fi

ok "Pre-flight checks passed"

# ── Step 2.1: Disable swap and configure kernel ─────────────────────
info "Disabling swap..."
sudo swapoff -a
ok "Swap disabled"

info "Loading br_netfilter module..."
sudo modprobe br_netfilter
if lsmod | grep br_netfilter; then
  ok "br_netfilter loaded"
else
  fail "Failed to load br_netfilter module"
fi

echo "br_netfilter" | sudo tee /etc/modules-load.d/k8s.conf
ok "br_netfilter persisted in /etc/modules-load.d/k8s.conf"

info "Configuring sysctl (bridge netfilter + IP forwarding)..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
ok "sysctl settings applied"

# ── Step 2.2: Install CNI plugins ───────────────────────────────────
info "Installing CNI plugins..."
sudo mkdir -p /opt/cni/bin
sudo cp "${BINARIES_DIR}/opt/cni/bin/"* /opt/cni/bin/
ok "CNI plugins → /opt/cni/bin/"

# ── Step 2.3: Install kubeadm, kubelet, crictl ──────────────────────
info "Installing kubeadm, kubelet, crictl..."
# Stop kubelet if running (binary is locked while the process is active)
if systemctl is-active --quiet kubelet; then
  sudo systemctl stop kubelet
  ok "Stopped running kubelet before overwriting binary"
fi
sudo cp "${BINARIES_DIR}/usr/local/bin"/{kubeadm,kubelet,crictl} /usr/local/bin/
sudo chmod +x /usr/local/bin/{kubeadm,kubelet,crictl}
ok "kubeadm, kubelet, crictl → /usr/local/bin/"

# ── Step 2.4: Install kubectl ───────────────────────────────────────
info "Installing kubectl..."
sudo install -o root -g root -m 0755 "${BINARIES_DIR}/kubectl" /usr/local/bin/kubectl
ok "kubectl → /usr/local/bin/kubectl"

# ── Step 2.5: Install kubelet systemd service ───────────────────────
info "Installing kubelet systemd service..."
sudo cp "${BINARIES_DIR}/usr/lib/systemd/system/kubelet.service" /usr/lib/systemd/system/kubelet.service
sudo mkdir -p /usr/lib/systemd/system/kubelet.service.d
sudo cp "${BINARIES_DIR}/usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf" \
   /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
sudo systemctl daemon-reload
sudo systemctl enable kubelet
ok "kubelet.service enabled"

# ── Step 2.6: Load container images ─────────────────────────────────
info "Loading container images (this may take a few minutes)..."
zcat "${IMAGES_DIR}/k8s_bundle.tar.gz" | sudo ctr -n k8s.io images import -
ok "Images loaded"

# ── Step 2.7: Re-tag Flannel image ──────────────────────────────────
info "Re-tagging Flannel image (docker.io → ghcr.io)..."
if sudo ctr -n k8s.io images ls -q | grep "ghcr.io/flannel-io/flannel:v0.28.1"; then
  ok "ghcr.io/flannel-io/flannel:v0.28.1 already exists — skipping re-tag"
else
  sudo ctr -n k8s.io images tag docker.io/flannel/flannel:v0.28.1 ghcr.io/flannel-io/flannel:v0.28.1
  ok "Flannel image re-tagged"
fi

# ── Step 2.8: Verify images ─────────────────────────────────────────
info "Verifying images..."
sudo ctr -n k8s.io images ls
IMAGE_COUNT=$(sudo ctr -n k8s.io images ls -q | wc -l)
if [ "${IMAGE_COUNT}" -lt 10 ]; then
  warn "Only ${IMAGE_COUNT} images found — expected at least 10"
else
  ok "${IMAGE_COUNT} images available"
fi

# ── Step 2.9: Configure containerd for SystemdCgroup ────────────────
info "Configuring containerd (SystemdCgroup = true)..."
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo sed -i 's|sandbox_image = "registry.k8s.io/pause:3.8"|sandbox_image = "registry.k8s.io/pause:3.10.1"|' /etc/containerd/config.toml
#sudo sed -i "s|sandbox = 'registry.k8s.io/pause:[^']*'|sandbox = 'registry.k8s.io/pause:3.10.1'|" /etc/containerd/config.toml
sudo systemctl restart containerd
ok "containerd restarted with SystemdCgroup + pause:3.10.1"

info "Base node setup complete (Steps 2.1–2.9)"
