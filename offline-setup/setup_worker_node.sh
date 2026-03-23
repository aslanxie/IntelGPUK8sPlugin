#!/usr/bin/env bash
#
# setup_worker_node.sh — Configure a worker node ready to join
# an existing Kubernetes cluster.
#
# This script sources setup_node_base.sh for common node setup
# (Steps 2.1–2.9), then prints next steps for joining the cluster.
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
#   chmod +x setup_worker_node.sh setup_node_base.sh
#   ./setup_worker_node.sh
#
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
BASE_DIR="$(pwd)"
BINARIES_DIR="${BASE_DIR}/binaries"
IMAGES_DIR="${BASE_DIR}/images"
MANIFESTS_DIR="${BASE_DIR}/manifests"

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

# ── Steps 2.1–2.9: Common node setup ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "${SCRIPT_DIR}/setup_node_base.sh" ]; then
  fail "setup_node_base.sh not found in ${SCRIPT_DIR}"
  check_exit
fi
source "${SCRIPT_DIR}/setup_node_base.sh"

# ── Summary ─────────────────────────────────────────────────────────
echo ""
if [ ${#ERRORS[@]} -gt 0 ]; then
  echo -e "\033[1;31m=== Worker node setup completed with errors ===\033[0m"
  for e in "${ERRORS[@]}"; do
    echo -e "  \033[1;31m✘\033[0m ${e}"
  done
  echo ""
  echo "Review the errors above and fix them before joining the cluster."
  exit 1
else
  echo -e "\033[1;32m=== Worker node setup complete! ===\033[0m"
  echo ""
  echo "  Next steps to join this node to the cluster:"
  echo ""
  echo "  1. On the CONTROL NODE, get the join command:"
  echo ""
  echo -e "     \033[1mkubeadm token create --print-join-command\033[0m"
  echo ""
  echo "  2. On THIS WORKER NODE, run the join command:"
  echo ""
  echo -e "     \033[1msudo kubeadm join <CONTROL_PLANE_IP>:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>\033[0m"
  echo ""
  echo "  3. On the CONTROL NODE, verify the worker node joined:"
  echo ""
  echo -e "     \033[1mkubectl get nodes\033[0m"
  echo ""
  echo "  The new worker node should appear and become Ready shortly."
  echo ""
fi
