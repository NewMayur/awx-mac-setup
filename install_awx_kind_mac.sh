#!/usr/bin/env bash
# ==============================================================================
# Script: install_awx_kind_mac.sh
# Description: Automated local installation of Red Hat AWX for macOS (Apple Silicon
#              M1/M2/M3/M4 & Intel x86_64, 2020-2025 models) using Kind and AWX Operator.
#
# Mac-Specific Considerations Handled:
#   1. OS Detection (Darwin): Verifies running on macOS.
#   2. Architecture Detection (arm64 vs amd64):
#      - Downloads native Darwin binaries for kind and kubectl.
#   3. Docker Desktop / OrbStack / Colima runtime checks:
#      - Checks for running Docker daemon and socket.
#      - Validates minimum recommended memory allocated to Docker (>= 6GB / 8GB recommended).
#   4. macOS Network / Port Binding:
#      - Replaces Linux `ss` with macOS native `lsof -iTCP:<PORT> -sTCP:LISTEN`.
#      - Intelligent port 30080 reuse detection if existing Kind container is listening.
#   5. Multi-Arch Container Images:
#      - AWX (>= 23.9.0) and AWX Operator (>= 2.12.2) natively support arm64.
#      - Patches kube-rbac-proxy to multi-arch quay.io/brancz/kube-rbac-proxy:v0.15.0.
#   6. Resilient Rollout & Pre-Wait Loops:
#      - Pre-checks pod scheduling before waiting for readiness to avoid premature exits.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration & Constants
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/bin"
KIND_VERSION="v0.24.0"
AWX_OPERATOR_VERSION="2.19.1"
AWX_PORT="30080"
ADMIN_USER="admin"
ADMIN_PASSWORD="admin123"
CLUSTER_NAME="awx-cluster"
NAMESPACE="awx"

KIND="${BIN_DIR}/kind"
KUBECTL="${BIN_DIR}/kubectl"

# Colors for clear terminal feedback
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ------------------------------------------------------------------------------
# Step 1: Pre-flight Checks (macOS environment)
# ------------------------------------------------------------------------------
log_info "Step 1: Checking macOS system prerequisites..."

OS_NAME=$(uname -s)
if [[ "${OS_NAME}" != "Darwin" ]]; then
    log_warn "This script is tailored for macOS (Darwin), but detected: ${OS_NAME}."
    log_warn "If running on Linux, prefer using './install_awx_kind.sh'."
fi

if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in your PATH."
    log_error "Please install Docker Desktop (https://www.docker.com/products/docker-desktop) or OrbStack (https://orbstack.dev)."
    exit 1
fi

if ! docker ps &> /dev/null; then
    log_error "Docker daemon is not reachable. Make sure Docker Desktop or OrbStack is started."
    exit 1
fi

# Check Docker memory allocation on macOS
DOCKER_MEM_BYTES=$(docker info --format '{{.TotalMemory}}' 2>/dev/null || echo "0")
if [[ "${DOCKER_MEM_BYTES}" -gt 0 ]]; then
    DOCKER_MEM_GB=$(( DOCKER_MEM_BYTES / 1024 / 1024 / 1024 ))
    if [[ "${DOCKER_MEM_GB}" -lt 6 ]]; then
        log_warn "Docker is allocated only ~${DOCKER_MEM_GB}GB of RAM."
        log_warn "AWX with PostgreSQL and Task containers requires at least 6GB to 8GB to run reliably."
        log_warn "Consider increasing Memory in Docker Desktop -> Settings -> Resources -> Advanced."
    else
        log_info "Docker memory allocated: ~${DOCKER_MEM_GB}GB (sufficient for AWX)."
    fi
fi

# Check for port conflict on 30080 using macOS native lsof
PORT_LISTENER=$(lsof -iTCP:"${AWX_PORT}" -sTCP:LISTEN -t 2>/dev/null || true)
if [[ -n "${PORT_LISTENER}" ]]; then
    if ! docker ps --filter "name=${CLUSTER_NAME}-control-plane" --format '{{.Names}}' | grep -q "${CLUSTER_NAME}-control-plane"; then
        log_error "Port ${AWX_PORT} is in use by another application (PID: ${PORT_LISTENER}). Please free port ${AWX_PORT} first."
        exit 1
    else
        log_info "Port ${AWX_PORT} is held by existing Kind cluster container '${CLUSTER_NAME}-control-plane' (reusing)."
    fi
fi

log_success "Docker & system prerequisites verified."

# ------------------------------------------------------------------------------
# Step 2: Download Standalone Darwin Binaries (kind & kubectl)
# ------------------------------------------------------------------------------
log_info "Step 2: Preparing local Darwin binaries in ${BIN_DIR}..."
mkdir -p "${BIN_DIR}"

RAW_ARCH=$(uname -m)
case "$RAW_ARCH" in
    arm64|aarch64)
        DARWIN_ARCH="arm64"
        log_info "Detected Apple Silicon architecture (arm64 - M1/M2/M3/M4 series)."
        ;;
    x86_64)
        DARWIN_ARCH="amd64"
        log_info "Detected Intel Mac architecture (x86_64)."
        ;;
    *)
        log_error "Unsupported macOS architecture: $RAW_ARCH"
        exit 1
        ;;
esac

# Download Kind for Darwin
if [[ ! -x "${KIND}" ]] || ! "${KIND}" version 2>/dev/null | grep -q "${KIND_VERSION}"; then
    log_info "Downloading kind for darwin-${DARWIN_ARCH} (${KIND_VERSION})..."
    curl -Lo "${KIND}" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-darwin-${DARWIN_ARCH}"
    chmod +x "${KIND}"
fi

# Download Kubectl for Darwin
if [[ ! -x "${KUBECTL}" ]]; then
    log_info "Downloading kubectl for darwin-${DARWIN_ARCH} (stable)..."
    K8S_STABLE=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -Lo "${KUBECTL}" "https://dl.k8s.io/release/${K8S_STABLE}/bin/darwin/${DARWIN_ARCH}/kubectl"
    chmod +x "${KUBECTL}"
fi

export PATH="${BIN_DIR}:${PATH}"
log_success "Binaries ready: kind $(${KIND} --version) and kubectl $(${KUBECTL} version --client --output=json 2>/dev/null | grep -o '\"gitVersion\": \"[^\"]*\"' | head -1)"

# ------------------------------------------------------------------------------
# Step 3: Create Kind Cluster with NodePort 30080 Mapping
# ------------------------------------------------------------------------------
log_info "Step 3: Configuring and starting Kind cluster '${CLUSTER_NAME}'..."

cat <<'CONFIG_EOF' > "${SCRIPT_DIR}/kind-config.yaml"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 30080
    listenAddress: "0.0.0.0"
    protocol: tcp
CONFIG_EOF

if "${KIND}" get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log_info "Kind cluster '${CLUSTER_NAME}' already exists. Reusing it."
else
    log_info "Creating new Kind cluster '${CLUSTER_NAME}'..."
    "${KIND}" create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml"
fi

"${KUBECTL}" wait --for=condition=ready node -l node-role.kubernetes.io/control-plane --timeout=120s
log_success "Kind cluster is ready with port ${AWX_PORT} mapped to host."

# ------------------------------------------------------------------------------
# Step 4: Create AWX Namespace and Static Admin Secret
# ------------------------------------------------------------------------------
log_info "Step 4: Setting up namespace '${NAMESPACE}' and admin secret..."

if ! "${KUBECTL}" get namespace "${NAMESPACE}" &>/dev/null; then
    "${KUBECTL}" create namespace "${NAMESPACE}"
fi

if ! "${KUBECTL}" -n "${NAMESPACE}" get secret awx-admin-password &>/dev/null; then
    "${KUBECTL}" -n "${NAMESPACE}" create secret generic awx-admin-password \
        --from-literal=password="${ADMIN_PASSWORD}"
    log_success "Created static admin password secret."
else
    log_info "Admin secret 'awx-admin-password' already exists."
fi

# ------------------------------------------------------------------------------
# Step 5: Deploy AWX Operator & Patch kube-rbac-proxy
# ------------------------------------------------------------------------------
log_info "Step 5: Deploying AWX Operator (${AWX_OPERATOR_VERSION})..."

cat <<'KUST_EOF' > "${SCRIPT_DIR}/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - github.com/ansible/awx-operator/config/default?ref=2.19.1
images:
  - name: quay.io/ansible/awx-operator
    newTag: 2.19.1
namespace: awx
KUST_EOF

log_info "Applying AWX Operator manifests via Kustomize..."
"${KUBECTL}" apply -k "${SCRIPT_DIR}"

log_info "Patching deprecated kube-rbac-proxy to multi-arch quay.io mirror..."
"${KUBECTL}" -n "${NAMESPACE}" set image deployment/awx-operator-controller-manager \
    kube-rbac-proxy=quay.io/brancz/kube-rbac-proxy:v0.15.0

log_info "Waiting for AWX Operator deployment rollout to complete..."
"${KUBECTL}" -n "${NAMESPACE}" rollout status deployment/awx-operator-controller-manager --timeout=600s
log_success "AWX Operator is running and healthy!"

# ------------------------------------------------------------------------------
# Step 6: Deploy AWX Custom Resource Instance
# ------------------------------------------------------------------------------
log_info "Step 6: Deploying AWX Custom Resource instance..."

cat <<'AWX_EOF' > "${SCRIPT_DIR}/awx-instance.yaml"
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
  namespace: awx
spec:
  service_type: NodePort
  nodeport_port: 30080
  admin_user: admin
  admin_password_secret: awx-admin-password
AWX_EOF

"${KUBECTL}" apply -f "${SCRIPT_DIR}/awx-instance.yaml"
log_success "AWX Custom Resource created. Operator is now provisioning Postgres and launching AWX..."

# ------------------------------------------------------------------------------
# Step 7: Wait for Deployment Completion (Resilient Polling)
# ------------------------------------------------------------------------------
log_info "Step 7: Waiting for AWX Web & Task services to be fully provisioned..."
log_info "Note: PostgreSQL migrations and container pulls take ~3-6 minutes on initial run."

# 1. Wait for Postgres pod
log_info "Waiting for PostgreSQL pod to be created and Ready..."
for i in {1..60}; do
    if "${KUBECTL}" -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=postgres-15 --no-headers 2>/dev/null | grep -q .; then
        break
    fi
    sleep 5
done
"${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=ready pod -l app.kubernetes.io/name=postgres-15 --timeout=360s || true

# 2. Wait for AWX Web pod
log_info "Waiting for awx-web pod to be created and Ready..."
for i in {1..90}; do
    if "${KUBECTL}" -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=awx-web --no-headers 2>/dev/null | grep -q .; then
        break
    fi
    sleep 5
done
"${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=ready pod -l app.kubernetes.io/name=awx-web --timeout=600s

# 3. Wait for AWX Task pod
log_info "Waiting for awx-task pod to be created and Ready..."
for i in {1..90}; do
    if "${KUBECTL}" -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=awx-task --no-headers 2>/dev/null | grep -q .; then
        break
    fi
    sleep 5
done
"${KUBECTL}" -n "${NAMESPACE}" wait --for=condition=ready pod -l app.kubernetes.io/name=awx-task --timeout=600s

log_success "All AWX pods are fully operational on macOS!"

# ------------------------------------------------------------------------------
# Step 8: Access Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}      🎉 AWX IS SUCCESSFULLY INSTALLED ON MACOS! 🎉             ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "  • Web UI URL  : ${BLUE}http://localhost:${AWX_PORT}${NC}"
echo -e "  • Username    : ${YELLOW}${ADMIN_USER}${NC}"
echo -e "  • Password    : ${YELLOW}${ADMIN_PASSWORD}${NC}"
echo -e "  • Cluster CLI : ${BLUE}${BIN_DIR}/kubectl -n ${NAMESPACE} get pods${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
