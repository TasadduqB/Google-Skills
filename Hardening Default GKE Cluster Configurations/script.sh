cat << 'EOF' > final_harden_fix.sh
#!/bin/bash

# ==============================================================================
# GSP496: Hardening Default GKE Cluster Configurations
# DYNAMIC ZONE + STATE RESET + ROBUST ERROR HANDLING
# ==============================================================================

# Fail on error
set -e

echo "========================================================"
echo "    INITIALIZING AUTOMATION"
echo "========================================================"

# 1. ROBUST ADMIN USER DETECTION
# We list ALL accounts, exclude service accounts, and grab the student email.
export ADMIN_USER=$(gcloud auth list --format="value(account)" | grep -v "iam.gserviceaccount.com" | grep -E "student|qwiklabs|google" | head -n 1)

if [ -z "$ADMIN_USER" ]; then
    echo "CRITICAL ERROR: Could not detect Student/Admin account."
    exit 1
fi

echo "Detected Admin User: $ADMIN_USER"
echo "Switching to Admin Context..."
gcloud config set account $ADMIN_USER

# 2. DYNAMIC CONFIGURATION
export PROJECT_ID=$(gcloud config get-value project)
export CLUSTER_NAME=simplecluster
export SA_NAME=demo-developer

# ==============================================================================
# PHASE 1: DYNAMIC CLUSTER & ZONE DETECTION
# ==============================================================================
echo "--------------------------------------------------------"
echo "Locating Cluster..."

# Check if cluster already exists in ANY zone
DETECTED_ZONE=$(gcloud container clusters list --filter="name:$CLUSTER_NAME" --format="value(location)" 2>/dev/null | head -n 1)

if [ -n "$DETECTED_ZONE" ]; then
  echo "Found existing cluster in: $DETECTED_ZONE"
  export MY_ZONE=$DETECTED_ZONE
else
  echo "Cluster not found. Attempting creation..."
  # Try zones sequentially to handle quotas
  ZONES=("us-central1-c" "us-east1-c" "us-west1-c" "us-central1-a" "us-east1-b")
  
  for ZONE in "${ZONES[@]}"; do
    echo "Attempting creation in $ZONE..."
    if gcloud container clusters create $CLUSTER_NAME --zone $ZONE --num-nodes 2 --metadata=disable-legacy-endpoints=false --quiet; then
      export MY_ZONE=$ZONE
      echo "SUCCESS: Cluster created in $MY_ZONE"
      break
    else
      echo "Failed in $ZONE. Trying next..."
    fi
  done
  
  if [ -z "$MY_ZONE" ]; then
    echo "ERROR: Could not create cluster. Region quotas might be full."
    exit 1
  fi
fi

echo "Target Zone: $MY_ZONE"


# Authenticate
gcloud container clusters get-credentials $CLUSTER_NAME --zone $MY_ZONE

# *** CRITICAL FIX: RESET NAMESPACE SECURITY ***
# If the lab was run before, the 'restricted' policy might be active, blocking Task 2.
# We remove it now so we can demonstrate the vulnerabilities.
echo "Resetting Namespace Policy (Allowing Vulnerable Pods)..."
kubectl label namespace default pod-security.kubernetes.io/enforce- --overwrite || true

# ==============================================================================
# PHASE 2: VULNERABILITY SIMULATION (Tasks 2-4)
# ==============================================================================
echo "[Task 2] Launching gcloud-sdk pod..."
kubectl delete pod gcloud --ignore-not-found=true --now

kubectl run gcloud --image=google/cloud-sdk:latest --restart=Never --command -- sleep 3600
echo "Waiting for pod..."
kubectl wait --for=condition=Ready pod/gcloud --timeout=120s

echo "  -> Exfiltrating kube-env (Sensitive Data)..."
kubectl exec gcloud -- curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/kube-env | head -n 5
kubectl delete pod gcloud --now

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

echo "[Task 4] Verifying Host Filesystem Access..."
kubectl exec hostpath -- ls /rootfs/bin | head -n 5
kubectl delete pod hostpath --now

# ==============================================================================
# PHASE 3: HARDENING (Tasks 5-7)
# ==============================================================================
echo "[Task 5] Creating Hardened Node Pool..."
# Attempt to create node pool; ignore if it already exists
gcloud beta container node-pools create second-pool \
    --cluster=$CLUSTER_NAME \
    --zone=$MY_ZONE \
    --num-nodes=1 \
    --metadata=disable-legacy-endpoints=true \
    --workload-metadata-from-node=SECURE \
    --quiet || echo "Node pool likely exists. Continuing..."

echo "[Task 6] Verifying Metadata Concealment..."
kubectl delete pod gcloud-secure --ignore-not-found=true --now
kubectl run gcloud-secure \
    --image=google/cloud-sdk:latest \
    --restart=Never \
    --overrides='{ "apiVersion": "v1", "spec": { "securityContext": { "runAsUser": 65534, "fsGroup": 65534 }, "nodeSelector": { "cloud.google.com/gke-nodepool": "second-pool" } } }' \
    --command -- sleep 3600

kubectl wait --for=condition=Ready pod/gcloud-secure --timeout=120s
echo "  -> Checking Metadata (Should be concealed)..."
kubectl exec gcloud-secure -- curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/kube-env
kubectl delete pod gcloud-secure --now

echo "[Task 7] Applying Pod Security Standards..."


# Bind Admin User
kubectl create clusterrolebinding clusteradmin \
    --clusterrole=cluster-admin \
    --user="$ADMIN_USER" || true

# Enforce Restricted Profile
kubectl label namespace default pod-security.kubernetes.io/enforce=restricted --overwrite

# Create Roles (Ignore if exists)
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
# PHASE 4: VERIFICATION (Task 8 - Fixed)
# ==============================================================================
echo "[Task 8] Setting up Service Account for Verification..."

# Reset Service Account
gcloud iam service-accounts delete "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet || true
echo "Creating Service Account..."
gcloud iam service-accounts create $SA_NAME --display-name="Demo Developer" --quiet

echo "Waiting 20s for Account Propagation..."
for i in {20..1}; do echo -ne "$i..."'\r'; sleep 1; done
echo ""

echo "Granting IAM Roles..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --role=roles/container.developer \
    --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --quiet

echo "Waiting 15s for Role Propagation..."
for i in {15..1}; do echo -ne "$i..."'\r'; sleep 1; done
echo ""

# Clean keys
rm -f key.json
echo "Creating Keys..."
gcloud iam service-accounts keys create key.json \
    --iam-account "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --quiet

echo "Waiting 45s for Key Validity (Critical for JWT)..."
for i in {45..1}; do echo -ne "$i..."'\r'; sleep 1; done
echo ""

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

chmod +x final_harden_fix.sh
./final_harden_fix.sh
