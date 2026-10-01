#!/usr/bin/env bash
# ==============================================================================
# Script: install_awx_minikube_mac.sh
# Description: Automated, error-free local installation of Red Hat AWX on macOS
#              (Apple Silicon M1/M2/M3/M4 & Intel 2020-2025) using Minikube & Docker.
#
# Highlights:
#   1. Validates Homebrew, Docker Desktop/OrbStack, Minikube, and Kubectl.
#   2. Enforces min 4 CPUs and 8192MB RAM for Minikube.
#   3. Clones/deploys AWX Operator with static admin password secret (admin / admin123).
#   4. Deploys AWX Custom Resource instance.
#   5. Uses resilient wait loops to prevent race conditions during DB migration and pod creation.
#   6. Displays the direct URL via minikube service.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWX_OPERATOR_VERSION="2.19.0"
ADMIN_USER="admin"
ADMIN_PASSWORD="admin123"
NAMESPACE="awx"
AWX_INSTANCE_NAME="my-awx"

# Formatting colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------------------------------------------------------
# Step 1: Pre-flight checks on macOS
# ------------------------------------------------------------------------------
log_info "Step 1: Checking macOS environment and prerequisites..."

if [[ "$(uname -s)" != "Darwin" ]]; then
    log_warn "Notice: This script is optimized for macOS (Darwin), but detected: $(uname -s)."
fi

# Check Docker daemon
if ! command -v docker &>/dev/null; then
    log_error "Docker is not installed or not in PATH."
    log_info "Install Docker Desktop via: brew install --cask docker"
    exit 1
fi

if ! docker ps &>/dev/null; then
    log_error "Docker daemon is not running. Please launch Docker Desktop from Applications."
    exit 1
fi

# Check Minikube
if ! command -v minikube &>/dev/null; then
    log_warn "Minikube not found. Attempting to install via Homebrew..."
    if command -v brew &>/dev/null; then
        brew install minikube
    else
        log_error "Homebrew not found. Please install minikube manually or install brew: https://brew.sh"
        exit 1
    fi
fi

# Check kubectl
if ! command -v kubectl &>/dev/null; then
    log_warn "kubectl not found. Attempting to install via Homebrew..."
    if command -v brew &>/dev/null; then
        brew install kubernetes-cli
    else
        log_error "Homebrew not found. Please install kubectl manually."
        exit 1
    fi
fi

# Check kustomize
if ! command -v kustomize &>/dev/null; then
    log_warn "kustomize not found. Attempting to install via Homebrew..."
    if command -v brew &>/dev/null; then
        brew install kustomize
    else
        log_warn "kustomize is recommended for operator deployment."
    fi
fi

log_success "Prerequisites verified."

# ------------------------------------------------------------------------------
# Step 2: Spin Up Minikube Cluster
# ------------------------------------------------------------------------------
log_info "Step 2: Checking Minikube status..."

if minikube status 2>/dev/null | grep -q "host: Running"; then
    log_info "Minikube cluster is already running. Reusing existing cluster."
else
    log_info "Starting Minikube cluster (4 CPUs, 8GB RAM, Docker driver, Ingress addon)..."
    minikube start --driver=docker --cpus=4 --memory=8192mb --addons=ingress
fi

log_success "Minikube cluster is ready."

# ------------------------------------------------------------------------------
# Step 3: Setup Namespace and Predictable Admin Secret
# ------------------------------------------------------------------------------
log_info "Step 3: Setting up '${NAMESPACE}' namespace and admin credentials..."

if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
    kubectl create namespace "${NAMESPACE}"
fi

kubectl config set-context --current --namespace="${NAMESPACE}"

# Pre-provision the admin secret so we don't have to decode random passwords
if ! kubectl -n "${NAMESPACE}" get secret "${AWX_INSTANCE_NAME}-admin-password" &>/dev/null; then
    kubectl -n "${NAMESPACE}" create secret generic "${AWX_INSTANCE_NAME}-admin-password" \
        --from-literal=password="${ADMIN_PASSWORD}"
    log_success "Created predictable admin secret '${AWX_INSTANCE_NAME}-admin-password'."
else
    log_info "Secret '${AWX_INSTANCE_NAME}-admin-password' already exists."
fi

# ------------------------------------------------------------------------------
# Step 4: Deploy AWX Operator
# ------------------------------------------------------------------------------
log_info "Step 4: Deploying AWX Operator (${AWX_OPERATOR_VERSION})..."

OPERATOR_DIR="${SCRIPT_DIR}/awx-operator"
if [[ ! -d "${OPERATOR_DIR}" ]]; then
    log_info "Cloning AWX Operator repository..."
    git clone https://github.com/ansible/awx-operator.git "${OPERATOR_DIR}"
fi

pushd "${OPERATOR_DIR}" > /dev/null
git fetch --tags
git checkout "${AWX_OPERATOR_VERSION}"

export NAMESPACE="${NAMESPACE}"
log_info "Running make deploy for AWX Operator..."
make deploy
popd > /dev/null

log_info "Patching deprecated kube-rbac-proxy image if necessary..."
# Ensure multi-arch quay.io mirror is used for Apple Silicon / Intel
kubectl -n "${NAMESPACE}" set image deployment/awx-operator-controller-manager \
    kube-rbac-proxy=quay.io/brancz/kube-rbac-proxy:v0.15.0 2>/dev/null || true

log_info "Waiting for AWX Operator controller manager rollout..."
kubectl -n "${NAMESPACE}" rollout status deployment/awx-operator-controller-manager --timeout=600s
log_success "AWX Operator is running and healthy!"

# ------------------------------------------------------------------------------
# Step 5: Deploy AWX Custom Resource Instance
# ------------------------------------------------------------------------------
log_info "Step 5: Applying AWX instance manifest..."

cat <<EOF > "${SCRIPT_DIR}/awx-minikube-instance.yaml"
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: ${AWX_INSTANCE_NAME}
  namespace: ${NAMESPACE}
spec:
  service_type: NodePort
  admin_user: ${ADMIN_USER}
  admin_password_secret: ${AWX_INSTANCE_NAME}-admin-password
EOF

kubectl apply -f "${SCRIPT_DIR}/awx-minikube-instance.yaml"
log_success "AWX instance registered with the operator."

# ------------------------------------------------------------------------------
# Step 6: Resilient Wait for Pods & Database Initialization
# ------------------------------------------------------------------------------
log_info "Step 6: Waiting for AWX database migrations and web/task pods..."
log_info "Note: PostgreSQL bootstrapping and image pulls take 4-8 minutes on initial launch."

# Wait for Postgres pod
log_info "Waiting for PostgreSQL pod..."
for i in {1..60}; do
    if kubectl -n "${NAMESPACE}" get pod -l "app.kubernetes.io/name=${AWX_INSTANCE_NAME}-postgres-15" --no-headers 2>/dev/null | grep -q .; then
        break
    fi
    if kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=postgres-15 --no-headers 2>/dev/null | grep -q .; then
        break
    fi
    sleep 5
done
kubectl -n "${NAMESPACE}" wait --for=condition=ready pod -l app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/component=database --timeout=360s 2>/dev/null || true

# Wait for AWX Web pod
log_info "Waiting for AWX web pod to start..."
for i in {1..90}; do
    if kubectl -n "${NAMESPACE}" get pod -l "app.kubernetes.io/name=${AWX_INSTANCE_NAME}-web" --no-headers 2>/dev/null | grep -q .; then
        break
    fi
    sleep 5
done
kubectl -n "${NAMESPACE}" wait --for=condition=ready pod -l "app.kubernetes.io/name=${AWX_INSTANCE_NAME}-web" --timeout=600s

# Wait for AWX Task pod
log_info "Waiting for AWX task pod to start..."
for i in {1..90}; do
    if kubectl -n "${NAMESPACE}" get pod -l "app.kubernetes.io/name=${AWX_INSTANCE_NAME}-task" --no-headers 2>/dev/null | grep -q .; then
        break
    fi
    sleep 5
done
kubectl -n "${NAMESPACE}" wait --for=condition=ready pod -l "app.kubernetes.io/name=${AWX_INSTANCE_NAME}-task" --timeout=600s

log_success "All AWX pods are fully operational on Minikube!"

# ------------------------------------------------------------------------------
# Step 7: Access Credentials & URL
# ------------------------------------------------------------------------------
AWX_URL=$(minikube service "${AWX_INSTANCE_NAME}-service" --namespace="${NAMESPACE}" --url 2>/dev/null || echo "Run: minikube service ${AWX_INSTANCE_NAME}-service --namespace=${NAMESPACE} --url")

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}    🎉 AWX IS SUCCESSFULLY INSTALLED ON MACOS (MINIKUBE)! 🎉    ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "  • Web UI URL  : ${BLUE}${AWX_URL}${NC}"
echo -e "  • Username    : ${YELLOW}${ADMIN_USER}${NC}"
echo -e "  • Password    : ${YELLOW}${ADMIN_PASSWORD}${NC}"
echo -e "  • Service Cmd : ${BLUE}minikube service ${AWX_INSTANCE_NAME}-service -n ${NAMESPACE}${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
