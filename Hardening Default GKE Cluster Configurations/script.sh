cat << 'EOF' > complete_harden_lab.sh
#!/bin/bash

# ==============================================================================
# GSP496: Hardening Default GKE Cluster Configurations
# COMPLETE AUTOMATED SOLUTION (With Fixes)
# ==============================================================================

# Fail on error
set -e

echo "========================================================"
echo "    DETECTING LAB CONFIGURATION"
echo "========================================================"

# 1. Auto-Detect Project ID
export PROJECT_ID=$(gcloud config get-value project)

# 2. Auto-Detect Assigned Zone
# Attempt 1: Check if a default zone is already set in gcloud config
echo "Detecting assigned zone..."
export MY_ZONE=$(gcloud config get-value compute/zone 2>/dev/null)

# Attempt 2: If config is unset, check Project Metadata (Standard for Qwiklabs)
if [ -z "$MY_ZONE" ] || [ "$MY_ZONE" == "(unset)" ]; then
  echo "Zone not in config. Checking project metadata..."
  MY_ZONE=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items.google-compute-default-zone)" 2>/dev/null)
  # Clean up the output if it returns a full URL
  MY_ZONE=${MY_ZONE##*/}
fi

# Attempt 3: If still empty, default to us-east1-c (since Central is often blocked)
if [ -z "$MY_ZONE" ] || [ "$MY_ZONE" == "(unset)" ]; then
  echo "Metadata empty. Defaulting to us-east1-c..."
  MY_ZONE="us-east1-c"
fi

# 3. Auto-Detect Admin User (Student Email)
# We grep for 'student' or 'google' to avoid picking service accounts
export ADMIN_USER=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -E "student|google" | head -n 1)

# Ensure we are running as the Admin User
gcloud config set account $ADMIN_USER

export CLUSTER_NAME=simplecluster
export SA_NAME=demo-developer

echo "--------------------------------------------------------"
echo "Project:  $PROJECT_ID"
echo "Zone:     $MY_ZONE"
echo "User:     $ADMIN_USER"
echo "--------------------------------------------------------"

# ==============================================================================
# Task 1: Create GKE Cluster
# ==============================================================================
echo "[Task 1] Creating GKE Cluster in $MY_ZONE..."


# Use quiet mode, but if it fails (already exists), echo a message and continue
gcloud container clusters create $CLUSTER_NAME \
    --zone $MY_ZONE \
    --num-nodes 2 \
    --metadata=disable-legacy-endpoints=false \
    --quiet || echo "Cluster might already exist. Proceeding..."

echo "[Task 1] Authenticating..."
gcloud container clusters get-credentials $CLUSTER_NAME --zone $MY_ZONE

# ==============================================================================
# Task 2: Metadata Exploration (Vulnerable State)
# ==============================================================================
echo "[Task 2] Launching gcloud-sdk pod..."
kubectl delete pod gcloud --ignore-not-found=true --now

kubectl run gcloud --image=google/cloud-sdk:latest --restart=Never --command -- sleep 3600
echo "Waiting for pod to be Ready..."
kubectl wait --for=condition=Ready pod/gcloud --timeout=120s

echo "  -> Attempting Metadata Access (Expect Failure)..."
kubectl exec gcloud -- curl -s http://metadata.google.internal/computeMetadata/v1/instance/name || true

echo "  -> Accessing with Header (Expect Success)..."
kubectl exec gcloud -- curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name

echo "  -> Exfiltrating kube-env (Sensitive Data)..."
kubectl exec gcloud -- curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/kube-env | head -n 5

kubectl delete pod gcloud --now

# ==============================================================================
# Task 3: Hostpath Vulnerability
# ==============================================================================
echo "[Task 3] Deploying vulnerable 'hostpath' pod..."

kubectl delete pod hostpath --ignore-not-found=true --now

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: hostpath
spec:
  containers:
  - name: hostpath
    image: google/cloud-sdk:latest
    command: ["/bin/bash"]
    args: ["-c", "tail -f /dev/null"]
    volumeMounts:
    - mountPath: /rootfs
      name: rootfs
  volumes:
  - name: rootfs
    hostPath:
      path: /
YAML

kubectl wait --for=condition=Ready pod/hostpath --timeout=60s

# ==============================================================================
# Task 4: Host Compromise Simulation
# ==============================================================================
echo "[Task 4] Verifying Host Filesystem Access..."
kubectl exec hostpath -- ls /rootfs/bin | head -n 5
kubectl delete pod hostpath --now

# ==============================================================================
# Task 5: Hardened Node Pool
# ==============================================================================
echo "[Task 5] Creating Hardened Node Pool in $MY_ZONE..."
gcloud beta container node-pools create second-pool \
    --cluster=$CLUSTER_NAME \
    --zone=$MY_ZONE \
    --num-nodes=1 \
    --metadata=disable-legacy-endpoints=true \
    --workload-metadata-from-node=SECURE \
    --quiet || echo "Node pool might already exist. Proceeding..."

# ==============================================================================
# Task 6: Verify Hardening
# ==============================================================================
echo "[Task 6] Deploying pod to hardened pool..."
kubectl delete pod gcloud-secure --ignore-not-found=true --now

kubectl run gcloud-secure \
    --image=google/cloud-sdk:latest \
    --restart=Never \
    --overrides='{ "apiVersion": "v1", "spec": { "securityContext": { "runAsUser": 65534, "fsGroup": 65534 }, "nodeSelector": { "cloud.google.com/gke-nodepool": "second-pool" } } }' \
    --command -- sleep 3600

kubectl wait --for=condition=Ready pod/gcloud-secure --timeout=120s

echo "  -> Checking Metadata Concealment (Should fail/be hidden)..."
kubectl exec gcloud-secure -- curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/kube-env
kubectl delete pod gcloud-secure --now

# ==============================================================================
# Task 7: Enforce Pod Security Standards
# ==============================================================================
echo "[Task 7] Setting up Pod Security Policies..."


# Ensure we use the Admin User Account detected earlier
kubectl create clusterrolebinding clusteradmin \
    --clusterrole=cluster-admin \
    --user="$ADMIN_USER" || true

# Enforce restricted profile
kubectl label namespace default pod-security.kubernetes.io/enforce=restricted --overwrite

# Create ClusterRole & Binding (Ignore if exists)
cat <<YAML | kubectl apply -f - || true
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
   name: pod-security-manager
rules:
- apiGroups: ['policy']
  resources: ['podsecuritypolicies']
  resourceNames: ['privileged', 'baseline', 'restricted']
  verbs: ['use']
- apiGroups: ['']
  resources: ['namespaces']
  verbs: ['get', 'list', 'watch', 'label']
YAML

cat <<YAML | kubectl apply -f - || true
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
   name: pod-security-modifier
   namespace: default
subjects:
- kind: Group
  apiGroup: rbac.authorization.k8s.io
  name: system:authenticated
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pod-security-manager
YAML

# ==============================================================================
# Task 8: Test Enforcement with Service Account (FIXED)
# ==============================================================================
echo "[Task 8] Setting up Service Account for Verification..."

# Reset Service Account
gcloud iam service-accounts delete "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet || true

echo "Creating Service Account..."
gcloud iam service-accounts create $SA_NAME --display-name="Demo Developer" --quiet

# *** CRITICAL FIX: WAIT FOR ACCOUNT PROPAGATION ***
echo "Waiting 20s for Account Propagation..."
for i in {20..1}; do echo -ne "$i..."'\r'; sleep 1; done
echo ""

echo "Granting IAM Roles..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --role=roles/container.developer \
    --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --quiet

# *** CRITICAL FIX: WAIT FOR ROLE PROPAGATION ***
echo "Waiting 20s for Role Propagation..."
for i in {20..1}; do echo -ne "$i..."'\r'; sleep 1; done
echo ""

# Clean keys
rm -f key.json
gcloud iam service-accounts keys create key.json \
    --iam-account "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --quiet

# Authenticate as SA
gcloud auth activate-service-account --key-file=key.json --quiet
gcloud container clusters get-credentials $CLUSTER_NAME --zone $MY_ZONE

echo "  -> Attempting to deploy VIOLATING pod (Expect Forbidden Error)..."
cat <<YAML | kubectl apply -f - || true
apiVersion: v1
kind: Pod
metadata:
  name: hostpath-bad
spec:
  containers:
  - name: hostpath
    image: google/cloud-sdk:latest
    command: ["/bin/bash"]
    args: ["-c", "tail -f /dev/null"]
    volumeMounts:
    - mountPath: /rootfs
      name: rootfs
  volumes:
  - name: rootfs
    hostPath:
      path: /
YAML

echo "  -> Deploying COMPLIANT pod (Expect Success)..."
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: hostpath-good-final
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: hostpath
    image: google/cloud-sdk:latest
    command: ["/bin/bash"]
    args: ["-c", "tail -f /dev/null"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
YAML

kubectl wait --for=condition=Ready pod/hostpath-good-final --timeout=120s

# CLEANUP: Switch back to Admin
gcloud config set account $ADMIN_USER

echo "========================================================"
echo "LAB COMPLETE - ALL TASKS FINISHED"
echo "========================================================"
EOF

chmod +x complete_harden_lab.sh
./complete_harden_lab.sh
