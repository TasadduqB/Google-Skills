cat << 'EOF' > complete_harden_lab.sh
#!/bin/bash

# ==============================================================================
# GSP496: Hardening Default GKE Cluster Configurations
# COMPLETE AUTOMATED SOLUTION
# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
export MY_ZONE=us-central1-c
export CLUSTER_NAME=simplecluster
export PROJECT_ID=$(gcloud config get-value project)
# Dynamically fetch the "Student" email to ensure we aren't using a Service Account
export USER_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep "student" | head -n 1)
export SA_NAME=demo-developer

echo "========================================================"
echo "Initializing Lab Automation"
echo "Project: $PROJECT_ID"
echo "Zone:    $MY_ZONE"
echo "User:    $USER_ACCOUNT"
echo "========================================================"

# Ensure we are running as the Admin User (fixes IAM permission errors)
gcloud config set account $USER_ACCOUNT

# ==============================================================================
# Task 1: Create GKE Cluster
# ==============================================================================
echo "[Task 1] Creating GKE Cluster (Approx 4-5 mins)..."
# We use '|| true' to allow the script to continue if the cluster already exists
gcloud container clusters create $CLUSTER_NAME \
    --zone $MY_ZONE \
    --num-nodes 2 \
    --metadata=disable-legacy-endpoints=false \
    --quiet || echo "Cluster may already exist, proceeding..."

echo "[Task 1] Authenticating..."
gcloud container clusters get-credentials $CLUSTER_NAME --zone $MY_ZONE

# ==============================================================================
# Task 2: Metadata Exploration (Vulnerable State)
# ==============================================================================
echo "[Task 2] Launching gcloud-sdk pod..."
# Delete if exists from previous run
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
echo "[Task 5] Creating Hardened Node Pool..."
gcloud beta container node-pools create second-pool \
    --cluster=$CLUSTER_NAME \
    --zone=$MY_ZONE \
    --num-nodes=1 \
    --metadata=disable-legacy-endpoints=true \
    --workload-metadata-from-node=SECURE \
    --quiet || echo "Node pool likely exists, proceeding..."

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

# Grant cluster-admin to current user
kubectl create clusterrolebinding clusteradmin \
    --clusterrole=cluster-admin \
    --user="$USER_ACCOUNT" || true

# Enforce restricted profile
kubectl label namespace default pod-security.kubernetes.io/enforce=restricted --overwrite

# Create ClusterRole & Binding (Ignore errors if they already exist)
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
# Task 8: Test Enforcement with Service Account
# ==============================================================================
echo "[Task 8] Setting up Service Account for Verification..."

# Reset Service Account
gcloud iam service-accounts delete "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet || true
gcloud iam service-accounts create $SA_NAME --display-name="Demo Developer" --quiet

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --role=roles/container.developer \
    --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --quiet

# Clean keys
rm -f key.json
gcloud iam service-accounts keys create key.json \
    --iam-account "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --quiet

echo "  -> Waiting 15s for key propagation..."
sleep 15

# Authenticate as SA
gcloud auth activate-service-account --key-file=key.json --quiet
gcloud container clusters get-credentials $CLUSTER_NAME --zone $MY_ZONE

echo "  -> Attempting to deploy VIOLATING pod (Expect Forbidden Error)..."
# Expect failure
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
# Ensure unique name to avoid cleanup conflicts
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

echo "========================================================"
echo "LAB COMPLETE - ALL TASKS FINISHED"
echo "========================================================"
EOF

chmod +x complete_harden_lab.sh
./complete_harden_lab.sh
