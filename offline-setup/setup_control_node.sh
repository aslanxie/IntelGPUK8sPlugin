#!/usr/bin/env bash
#
# setup_control_node.sh — Initialize the Kubernetes control plane
# and deploy Flannel + Intel GPU plugin.
#
# This script sources setup_node_base.sh for common node setup
# (Steps 2.1–2.9), then performs control-plane-specific steps
# (Steps 2.10–2.17).
#
# Expected layout (created by prepare_online.sh):
#   $(pwd)/
#   ├── binaries/
#   │   ├── kubectl
#   │   ├── opt/cni/bin/...
#   │   └── usr/local/bin/{kubeadm,kubelet,crictl}
#   │       └── lib/systemd/system/kubelet.service{,.d/10-kubeadm.conf}
#   ├── images/
#   │   └── k8s_bundle.tar.gz
#   ├── manifests/
#   │   ├── kube-flannel.yml
#   │   ├── nfd.yaml
#   │   ├── nfd-gpu-rules.yaml
#   │   └── gpu-plugin.yaml
#   └── setup_node_base.sh
#
# Usage:
#   cd /home/gta/workspace/intel_gpu_k8s
#   chmod +x setup_control_node.sh setup_node_base.sh
#   ./setup_control_node.sh
#
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
BASE_DIR="$(pwd)"
BINARIES_DIR="${BASE_DIR}/binaries"
IMAGES_DIR="${BASE_DIR}/images"
MANIFESTS_DIR="${BASE_DIR}/manifests"

K8S_VERSION="v1.35.2"
POD_NETWORK_CIDR="10.244.0.0/16"

# Timeout (seconds) to wait for pods to become Ready
POD_WAIT_TIMEOUT=120

# ── Helpers ──────────────────────────────────────────────────────────
info()  { echo -e "\n\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m  ✔\033[0m $*"; }
warn()  { echo -e "\033[1;33m  ⚠\033[0m $*" >&2; }
fail()  { echo -e "\033[1;31m  ✘ $*\033[0m" >&2; ERRORS+=("$*"); }

ERRORS=()

check_exit() {
  if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo -e "\033[1;31m=== Errors encountered ===\033[0m"
    for e in "${ERRORS[@]}"; do
      echo -e "  \033[1;31m✘\033[0m ${e}"
    done
    exit 1
  fi
}

# Wait for all pods matching a label/namespace to be Ready.
# Usage: wait_for_pods <namespace> <description> [extra kubectl args...]
wait_for_pods() {
  local ns="$1" desc="$2"
  shift 2
  info "Waiting for ${desc} pods to be Ready (timeout: ${POD_WAIT_TIMEOUT}s)..."

  local deadline=$(( $(date +%s) + POD_WAIT_TIMEOUT ))
  while true; do
    # Count not-ready pods (STATUS != Running/Completed/Succeeded)
    local not_ready
    not_ready=$(kubectl get pods -n "${ns}" "$@" --no-headers 2>/dev/null \
      | grep -cvE '(Running|Completed|Succeeded)' || true)

    local total
    total=$(kubectl get pods -n "${ns}" "$@" --no-headers 2>/dev/null | wc -l || echo 0)

    if [ "${total}" -gt 0 ] && [ "${not_ready}" -eq 0 ]; then
      ok "All ${desc} pods are Running"
      kubectl get pods -n "${ns}" "$@" --no-headers 2>/dev/null | sed 's/^/    /'
      return 0
    fi

    if [ "$(date +%s)" -ge "${deadline}" ]; then
      fail "${desc}: ${not_ready} pod(s) not ready after ${POD_WAIT_TIMEOUT}s"
      kubectl get pods -n "${ns}" "$@" --no-headers 2>/dev/null | sed 's/^/    /'
      return 1
    fi

    sleep 5
  done
}

# ── Steps 2.1–2.9: Common node setup ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "${SCRIPT_DIR}/setup_node_base.sh" ]; then
  fail "setup_node_base.sh not found in ${SCRIPT_DIR}"
  check_exit
fi
source "${SCRIPT_DIR}/setup_node_base.sh"

# ── Step 4: Initialize control plane ────────────────────────────────
info "Initializing Kubernetes control plane (${K8S_VERSION})..."
if [ -f /etc/kubernetes/admin.conf ]; then
  warn "Cluster already initialized — skipping kubeadm init"
else
  sudo HTTP_PROXY="" HTTPS_PROXY="" NO_PROXY="*" \
    kubeadm init --kubernetes-version="${K8S_VERSION}" --pod-network-cidr="${POD_NETWORK_CIDR}"
  if [ $? -ne 0 ]; then
    fail "kubeadm init failed"
    check_exit
  fi
  ok "kubeadm init complete"
fi

# Configure kubectl for the current user
info "Configuring kubectl for user '$(whoami)'..."
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"
ok "kubeconfig → $HOME/.kube/config"

# Remove control-plane taint so pods can schedule on single-node
info "Removing control-plane taint (allow workloads on control node)..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
ok "Taint removed"

# Verify node is visible
info "Verifying control plane node..."
kubectl get nodes --no-headers | sed 's/^/    /'

# ── Step 5: Deploy Flannel CNI ──────────────────────────────────────
info "Deploying Flannel CNI..."
if ! kubectl apply -f "${MANIFESTS_DIR}/kube-flannel.yml"; then
  fail "Failed to apply kube-flannel.yml"
else
  ok "kube-flannel.yml applied"
fi

wait_for_pods "kube-flannel" "Flannel" || true

# Wait for node to become Ready
info "Waiting for node to become Ready..."
NODE_READY_DEADLINE=$(( $(date +%s) + POD_WAIT_TIMEOUT ))
while true; do
  NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
  if echo "${NODE_STATUS}" | grep "Ready" > /dev/null; then
    ok "Node is Ready"
    kubectl get nodes --no-headers | sed 's/^/    /'
    break
  fi
  if [ "$(date +%s)" -ge "${NODE_READY_DEADLINE}" ]; then
    fail "Node not Ready after ${POD_WAIT_TIMEOUT}s"
    kubectl get nodes --no-headers | sed 's/^/    /'
    break
  fi
  sleep 5
done

# ── Step 6: Deploy Intel GPU Plugin ─────────────────────────────────

# 6.1 NFD
info "Deploying Node Feature Discovery (NFD)..."
if ! kubectl apply -f "${MANIFESTS_DIR}/nfd.yaml"; then
  fail "Failed to apply nfd.yaml"
else
  ok "nfd.yaml applied"
fi

wait_for_pods "node-feature-discovery" "NFD" || true

# 6.2 GPU Node Feature Rules
info "Deploying GPU Node Feature Rules..."
if ! kubectl apply -f "${MANIFESTS_DIR}/nfd-gpu-rules.yaml"; then
  fail "Failed to apply nfd-gpu-rules.yaml"
else
  ok "nfd-gpu-rules.yaml applied"
fi

# 6.3 Intel GPU Device Plugin
info "Deploying Intel GPU Device Plugin..."
if ! kubectl apply -f "${MANIFESTS_DIR}/gpu-plugin.yaml"; then
  fail "Failed to apply gpu-plugin.yaml"
else
  ok "gpu-plugin.yaml applied"
fi

# Wait and check for GPU plugin pods — try common namespaces
info "Checking GPU plugin pod status..."
GPU_NS=""
for ns in "intel-gpu-plugin" "inteldeviceplugins-system" "default" "kube-system"; do
  if kubectl get pods -n "${ns}" --no-headers 2>/dev/null | grep "gpu" > /dev/null; then
    GPU_NS="${ns}"
    break
  fi
done

if [ -n "${GPU_NS}" ]; then
  wait_for_pods "${GPU_NS}" "Intel GPU plugin" || true
else
  # The DaemonSet may take a moment to create pods
  sleep 10
  for ns in "intel-gpu-plugin" "inteldeviceplugins-system" "default" "kube-system"; do
    if kubectl get pods -n "${ns}" --no-headers 2>/dev/null | grep "gpu" > /dev/null; then
      GPU_NS="${ns}"
      break
    fi
  done
  if [ -n "${GPU_NS}" ]; then
    wait_for_pods "${GPU_NS}" "Intel GPU plugin" || true
  else
    warn "Could not find GPU plugin pods in any expected namespace"
    echo "    Checking all namespaces for gpu-related pods:"
    kubectl get pods --all-namespaces 2>/dev/null | grep -i gpu | sed 's/^/    /' || true
  fi
fi

# ── Step 7: Verify GPU resources ────────────────────────────────────
info "Verifying GPU resources on nodes..."
sleep 5
GPU_RESOURCES=$(kubectl get nodes -o json 2>/dev/null \
  | grep -o '"gpu\.intel\.com/[^"]*": "[^"]*"' || true)

if [ -n "${GPU_RESOURCES}" ]; then
  ok "GPU resources detected:"
  echo "${GPU_RESOURCES}" | sed 's/^/    /'
else
  warn "No gpu.intel.com resources found yet. The GPU plugin may still be initializing."
  echo "    Check manually: kubectl get nodes -o json | jq '.items[].status.allocatable' | grep gpu"
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
info "All pod status:"
kubectl get pods --all-namespaces --no-headers 2>/dev/null | sed 's/^/    /'

echo ""
if [ ${#ERRORS[@]} -gt 0 ]; then
  echo -e "\033[1;31m=== Setup completed with errors ===\033[0m"
  for e in "${ERRORS[@]}"; do
    echo -e "  \033[1;31m✘\033[0m ${e}"
  done
  echo ""
  echo "Review the errors above and check logs:"
  echo "  journalctl -xeu kubelet"
  echo "  kubectl describe pod <pod-name> -n <namespace>"
  exit 1
else
  echo -e "\033[1;32m=== Control node setup complete! ===\033[0m"
  echo ""
  echo "  Node status:"
  kubectl get nodes 2>/dev/null | sed 's/^/    /'
  echo ""
  echo "  GPU resources:"
  kubectl get nodes -o json 2>/dev/null \
    | grep -o '"gpu\.intel\.com/[^"]*": "[^"]*"' | sed 's/^/    /' || echo "    (not yet available — check again shortly)"
  echo ""
fi
