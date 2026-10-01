# Local AWX Deployment on macOS (Apple Silicon & Intel, 2020–2025)

This guide provides tested, error-free instructions and automated scripts to run **Red Hat AWX** on any modern Mac (**Apple Silicon M1/M2/M3/M4 or Intel 2020–2025**).

Because modern Ansible AWX (v18+) no longer supports standalone Docker Compose, it is deployed via the **AWX Operator** inside a local Kubernetes cluster. On macOS, there are two primary methods:
1. **Method A (Recommended): Minikube + Docker Desktop** (native cluster integration, standard across Mac guides).
2. **Method B: Kind (Kubernetes-in-Docker)** (zero sudo/Homebrew requirements, standalone binaries).

---

## 1. Quick Access Summary

* **Web UI URL (Minikube)**: Provided dynamically by `minikube service my-awx-service -n awx --url`
* **Web UI URL (Kind)**: [http://localhost:30080](http://localhost:30080)
* **Default Username**: `admin`
* **Default Password**: `admin123` (or decoded from the cluster secret)
* **Supported Macs**: All 2020–2025 Mac models (MacBook Pro, Air, Mac mini, Mac Studio, iMac with M1/M2/M3/M4 chips or Intel Core i5/i7/i9).

---

## 2. Automated One-Click Installation Scripts

Choose the installation method suited to your environment:

### Option A: Using Minikube (Recommended for macOS Developers)
Uses Homebrew, Minikube, and Docker Desktop:

```bash
cd /path/to/awx
chmod +x ./install_awx_minikube_mac.sh
./install_awx_minikube_mac.sh
```

### Option B: Using Kind (Standalone Binaries, No Homebrew Needed)
Uses self-contained Kind and Kubectl binaries in `./bin`:

```bash
cd /path/to/awx
chmod +x ./install_awx_kind_mac.sh
./install_awx_kind_mac.sh
```

Both scripts automatically handle architecture detection (`arm64` vs `amd64`), create predictable admin credentials, patch upstream image bugs, and wait resiliently for all AWX services to come online.

---

## 3. Step-by-Step Manual Guide (Minikube Method)

### Step 1: Install Dependencies via Homebrew
Open Terminal on your Mac:
```bash
# Install Docker Desktop (if not already installed)
brew install --cask docker

# Install Minikube
brew install minikube

# Install kubectl
brew install kubernetes-cli

# Install kustomize
brew install kustomize
```
> [!IMPORTANT]
> Launch **Docker.app** from your Applications folder and wait until the Docker engine status shows green/running before continuing.

### Step 2: Spin Up the Minikube Cluster
AWX components (PostgreSQL, awx-web, awx-task, and operator) require sufficient memory to prevent OOM kills:
```bash
minikube start --driver=docker --cpus=4 --memory=8192mb --addons=ingress
```

### Step 3: Deploy the AWX Operator
```bash
# 1. Clone the official AWX Operator repository
git clone https://github.com/ansible/awx-operator.git
cd awx-operator

# 2. Check out a stable release tag
git checkout 2.19.0

# 3. Create dedicated namespace and set context
export NAMESPACE=awx
kubectl create namespace ${NAMESPACE}
kubectl config set-context --current --namespace=${NAMESPACE}

# 4. Deploy operator to cluster
make deploy

# 5. Patch upstream deprecated kube-rbac-proxy image (for multi-arch M1-M4 support)
kubectl -n awx set image deployment/awx-operator-controller-manager \
    kube-rbac-proxy=quay.io/brancz/kube-rbac-proxy:v0.15.0

# 6. Verify operator rollout
kubectl -n awx rollout status deployment/awx-operator-controller-manager --timeout=600s
```

### Step 4: Deploy the AWX Instance
Return to your working directory and create `awx-instance.yaml`:
```yaml
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: my-awx
  namespace: awx
spec:
  service_type: NodePort
```

Apply the configuration:
```bash
kubectl apply -f awx-instance.yaml
```

Monitor pod initialization (initial database migrations and container downloads take 5–8 minutes):
```bash
kubectl get pods -n awx -w
```
Wait until `my-awx-postgres-15-0`, `my-awx-web`, and `my-awx-task` are all in `Running` status.

### Step 5: Retrieve Credentials and Access Web UI
Extract the auto-generated admin password:
```bash
kubectl -n awx get secret my-awx-admin-password -o jsonpath="{.data.password}" | base64 --decode; echo
```

Expose the AWX portal to your browser:
```bash
minikube service my-awx-service -n awx --url
```
Open the output URL in Safari or Chrome and log in with username `admin` and the decoded password.

---

## 4. Testing for Free with GitHub Actions (No Physical Mac Needed)

If you do not have a physical Mac, you can test these exact instructions on real cloud macOS virtual machines using GitHub Actions for free.

Create `.github/workflows/test-awx-mac.yml` in your repository:

```yaml
name: Test AWX Installation on macOS
on: [push, workflow_dispatch]

jobs:
  test-mac-install:
    # Runs on free cloud Apple Silicon/Intel macOS runners
    runs-on: macos-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Install System Dependencies via Homebrew
        run: |
          brew install minikube kubernetes-cli kustomize

      - name: Start Minikube Cluster
        run: |
          # Headless macOS runners use the native hypervisor driver
          minikube start --driver=qemu --cpus=3 --memory=6144mb

      - name: Clone and Deploy AWX Operator
        run: |
          git clone https://github.com/ansible/awx-operator.git
          cd awx-operator
          git checkout 2.19.0
          export NAMESPACE=awx
          kubectl create namespace ${NAMESPACE}
          kubectl config set-context --current --namespace=${NAMESPACE}
          make deploy
          kubectl -n awx set image deployment/awx-operator-controller-manager \
            kube-rbac-proxy=quay.io/brancz/kube-rbac-proxy:v0.15.0
          kubectl -n awx rollout status deployment/awx-operator-controller-manager --timeout=600s

      - name: Deploy AWX Instance Configuration
        run: |
          cat <<EOF > awx-instance.yaml
          apiVersion: awx.ansible.com/v1beta1
          kind: AWX
          metadata:
            name: my-awx
            namespace: awx
          spec:
            service_type: NodePort
          EOF
          kubectl apply -f awx-instance.yaml

      - name: Wait for Successful Database and Deployment Initialization
        run: |
          echo "Waiting for pods to stabilize (takes ~5-8 minutes)..."
          # Resilient wait loop for database and web/task pods
          for i in {1..60}; do
            if kubectl -n awx get pod -l app.kubernetes.io/name=my-awx-web --no-headers 2>/dev/null | grep -q .; then
              break
            fi
            sleep 5
          done
          kubectl -n awx wait --for=condition=ready pod -l app.kubernetes.io/name=my-awx-web --timeout=600s
          kubectl -n awx wait --for=condition=ready pod -l app.kubernetes.io/name=my-awx-task --timeout=600s

      - name: Extract Admin Password and Validate Service
        run: |
          PASSWORD=$(kubectl -n awx get secret my-awx-admin-password -o jsonpath="{.data.password}" | base64 --decode)
          echo "Decrypted Admin Password: $PASSWORD"
          kubectl -n awx get svc my-awx-service
```

---

## 5. Daily Cluster Management on macOS

To preserve battery and CPU cycles when not testing:

```bash
# Minikube cluster management
minikube pause    # Pauses VM processes without losing data
minikube unpause  # Instantly resumes AWX
minikube stop     # Shuts down Minikube VM
minikube start    # Restarts Minikube VM

# Teardown
minikube delete --all
```
