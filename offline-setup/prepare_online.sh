#!/usr/bin/env bash
#
# prepare_online.sh — Run on an internet-connected machine to download
# all images, binaries, and manifests needed for an air-gapped
# Kubernetes + Intel GPU plugin deployment.
#
# Usage:
#   ./prepare_online.sh                        # uses ./intel_gpu_k8s/ as staging dir
#   STAGING_DIR=/tmp/mybundle ./prepare_online.sh  # custom staging dir
#
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
STAGING_DIR="${STAGING_DIR:-$(pwd)/intel_gpu_k8s}"

K8S_VERSION="v1.35.2"
ETCD_VERSION="3.6.6-0"
COREDNS_VERSION="v1.13.1"
PAUSE_VERSION="3.10.1"
FLANNEL_VERSION="v0.28.1"
FLANNEL_CNI_VERSION="v1.9.0-flannel1"
NFD_VERSION="v0.18.3"
INTEL_GPU_PLUGIN_VERSION="0.35.0"
INTEL_DEVICE_PLUGINS_REF="v0.35.0"
CNI_PLUGINS_VERSION="v1.3.0"
CRICTL_VERSION="v1.31.0"
KUBELET_SERVICE_VERSION="v0.16.2"
ARCH="amd64"

# ── Helper ───────────────────────────────────────────────────────────
info()  { echo -e "\n\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m  ✔\033[0m $*"; }
fail()  { echo -e "\033[1;31m  ✘ $*\033[0m" >&2; exit 1; }

# ── Create staging directory ─────────────────────────────────────────
info "Staging directory: ${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"/{manifests,binaries/opt/cni/bin,binaries/usr/local/bin,binaries/usr/lib/systemd/system/kubelet.service.d,images}

# ── 1. Kustomize ─────────────────────────────────────────────────────
info "Checking for kustomize..."
if command -v kustomize &>/dev/null; then
    ok "kustomize already installed: $(kustomize version --short 2>/dev/null || kustomize version)"
    KUSTOMIZE_BIN="kustomize"
elif [ -x "./kustomize" ]; then
    ok "kustomize found in current directory"
    KUSTOMIZE_BIN="./kustomize"
else
    info "kustomize not found — installing..."
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
    KUSTOMIZE_BIN="./kustomize"
    ok "kustomize installed"
fi

# ── 2. Download Kubernetes manifests ─────────────────────────────────
info "Downloading manifests..."

echo "  NFD base..."
${KUSTOMIZE_BIN} build \
  "https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd?ref=${INTEL_DEVICE_PLUGINS_REF}" \
  > "${STAGING_DIR}/manifests/nfd.yaml"
ok "nfd.yaml"

echo "  GPU NodeFeatureRules..."
${KUSTOMIZE_BIN} build \
  "https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd/overlays/node-feature-rules?ref=${INTEL_DEVICE_PLUGINS_REF}" \
  > "${STAGING_DIR}/manifests/nfd-gpu-rules.yaml"
ok "nfd-gpu-rules.yaml"

echo "  GPU plugin (NFD-labeled nodes overlay)..."
${KUSTOMIZE_BIN} build \
  "https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/gpu_plugin/overlays/nfd_labeled_nodes?ref=${INTEL_DEVICE_PLUGINS_REF}" \
  > "${STAGING_DIR}/manifests/gpu-plugin.yaml"
ok "gpu-plugin.yaml"

echo "  Flannel CNI manifest..."
wget -q -O "${STAGING_DIR}/manifests/kube-flannel.yml" \
  https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
ok "kube-flannel.yml"

# ── 3. Pull container images ────────────────────────────────────────
info "Pulling container images..."

IMAGES=(
  "registry.k8s.io/kube-apiserver:${K8S_VERSION}"
  "registry.k8s.io/kube-proxy:${K8S_VERSION}"
  "registry.k8s.io/kube-scheduler:${K8S_VERSION}"
  "registry.k8s.io/kube-controller-manager:${K8S_VERSION}"
  "registry.k8s.io/etcd:${ETCD_VERSION}"
  "registry.k8s.io/coredns/coredns:${COREDNS_VERSION}"
  "registry.k8s.io/pause:${PAUSE_VERSION}"
  "docker.io/flannel/flannel:${FLANNEL_VERSION}"
  "ghcr.io/flannel-io/flannel-cni-plugin:${FLANNEL_CNI_VERSION}"
  "registry.k8s.io/nfd/node-feature-discovery:${NFD_VERSION}"
  "intel/intel-gpu-plugin:${INTEL_GPU_PLUGIN_VERSION}"
  "intel/intel-gpu-levelzero:${INTEL_GPU_PLUGIN_VERSION}"
)

for img in "${IMAGES[@]}"; do
  echo "  ${img}"
  docker pull "${img}"
done
ok "All images pulled"

# ── 4. Save images to a single archive ──────────────────────────────
info "Saving images to k8s_bundle.tar.gz..."
docker save "${IMAGES[@]}" | gzip > "${STAGING_DIR}/images/k8s_bundle.tar.gz"
ok "k8s_bundle.tar.gz ($(du -h "${STAGING_DIR}/images/k8s_bundle.tar.gz" | cut -f1))"

# ── 5. Download Kubernetes binaries ─────────────────────────────────
info "Downloading CNI plugins ${CNI_PLUGINS_VERSION}..."
curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz" \
  | tar -C "${STAGING_DIR}/binaries/opt/cni/bin" -xz
ok "CNI plugins"

info "Downloading crictl ${CRICTL_VERSION}..."
curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" \
  | tar -C "${STAGING_DIR}/binaries/usr/local/bin" -xz
ok "crictl"

RELEASE="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
info "Downloading kubeadm & kubelet (${RELEASE})..."
curl -L -o "${STAGING_DIR}/binaries/usr/local/bin/kubeadm" \
  "https://dl.k8s.io/release/${RELEASE}/bin/linux/${ARCH}/kubeadm"
curl -L -o "${STAGING_DIR}/binaries/usr/local/bin/kubelet" \
  "https://dl.k8s.io/release/${RELEASE}/bin/linux/${ARCH}/kubelet"
chmod +x "${STAGING_DIR}/binaries/usr/local/bin"/{kubeadm,kubelet}
ok "kubeadm & kubelet"

info "Downloading kubectl (${RELEASE})..."
curl -L -o "${STAGING_DIR}/binaries/kubectl" \
  "https://dl.k8s.io/release/${RELEASE}/bin/linux/${ARCH}/kubectl"
chmod +x "${STAGING_DIR}/binaries/kubectl"
ok "kubectl"

info "Downloading kubelet systemd service files..."
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${KUBELET_SERVICE_VERSION}/cmd/krel/templates/latest/kubelet/kubelet.service" \
  | sed "s:/usr/bin:/usr/local/bin:g" \
  > "${STAGING_DIR}/binaries/usr/lib/systemd/system/kubelet.service"

curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${KUBELET_SERVICE_VERSION}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf" \
  | sed "s:/usr/bin:/usr/local/bin:g" \
  > "${STAGING_DIR}/binaries/usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf"
ok "kubelet.service & 10-kubeadm.conf"

# ── Summary ─────────────────────────────────────────────────────────
info "Preparation complete! Staging directory layout:"
echo ""
find "${STAGING_DIR}" -type f | sort | while read -r f; do
  echo "  ${f#${STAGING_DIR}/}"
done
echo ""
info "Next step: copy ${STAGING_DIR}/ to your target server(s)."
echo "  Example:  scp -r ${STAGING_DIR} <user>@<target-host>:~/"
