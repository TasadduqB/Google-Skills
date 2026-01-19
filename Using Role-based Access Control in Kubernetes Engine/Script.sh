cat > gke_rbac_lab_full_dynamic.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# -----------------------------
# Dynamic Project ID
# -----------------------------
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)

if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: gcloud project is not set. Please set the project first."
  echo "Run: gcloud config set project PROJECT_ID"
  exit 1
fi

# -----------------------------
# Dynamic Cluster Name
# (assumes only one cluster exists in the project)
# -----------------------------
CLUSTER_NAME=$(gcloud container clusters list --project "$PROJECT_ID" --format="value(name)" | head -n 1)

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: No GKE cluster found in project $PROJECT_ID"
  exit 1
fi

# -----------------------------
# Get dynamic zone from cluster
# -----------------------------
ZONE=$(gcloud container clusters describe "$CLUSTER_NAME" \
  --project="$PROJECT_ID" \
  --format="value(location)")

# -----------------------------
# Get region from zone
# -----------------------------
REGION=$(echo "$ZONE" | sed 's/-[a-z]$//')

# -----------------------------
# Ensure project/zone are set
# -----------------------------
gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/zone "$ZONE" --quiet
gcloud config set compute/region "$REGION" --quiet

# -----------------------------
# Get instance names (Admin / Owner / Auditor)
# -----------------------------
ADMIN_INSTANCE=$(gcloud compute instances list \
  --project "$PROJECT_ID" \
  --filter="name~admin" \
  --format="value(name)" | head -n 1)

OWNER_INSTANCE=$(gcloud compute instances list \
  --project "$PROJECT_ID" \
  --filter="name~owner" \
  --format="value(name)" | head -n 1)

AUDITOR_INSTANCE=$(gcloud compute instances list \
  --project "$PROJECT_ID" \
  --filter="name~auditor" \
  --format="value(name)" | head -n 1)

# -----------------------------
# Validate instances exist
# -----------------------------
if [[ -z "$ADMIN_INSTANCE" ]] || [[ -z "$OWNER_INSTANCE" ]] || [[ -z "$AUDITOR_INSTANCE" ]]; then
  echo "ERROR: One or more lab instances not found."
  echo "Admin: $ADMIN_INSTANCE"
  echo "Owner: $OWNER_INSTANCE"
  echo "Auditor: $AUDITOR_INSTANCE"
  exit 1
fi

echo "Project: $PROJECT_ID"
echo "Cluster: $CLUSTER_NAME"
echo "Zone: $ZONE"
echo "Region: $REGION"
echo "Admin: $ADMIN_INSTANCE"
echo "Owner: $OWNER_INSTANCE"
echo "Auditor: $AUDITOR_INSTANCE"

# -----------------------------
# Step 1: Create RBAC rules (Admin)
# -----------------------------
gcloud compute ssh "$ADMIN_INSTANCE" --zone "$ZONE" --project "$PROJECT_ID" --command="bash -s" <<'EOF_ADMIN'
set -euo pipefail

sudo apt-get update -y
sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin

echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
source ~/.bashrc

gcloud container clusters get-credentials rbac-demo-cluster --zone "$(gcloud config get-value compute/zone)" --project "$(gcloud config get-value project)"
kubectl apply -f ./manifests/rbac.yaml
EOF_ADMIN

# -----------------------------
# Step 2: Owner creates deployments
# -----------------------------
gcloud compute ssh "$OWNER_INSTANCE" --zone "$ZONE" --project "$PROJECT_ID" --command="bash -s" <<'EOF_OWNER'
set -euo pipefail

sudo apt-get update -y
sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin

echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
source ~/.bashrc

gcloud container clusters get-credentials rbac-demo-cluster --zone "$(gcloud config get-value compute/zone)" --project "$(gcloud config get-value project)"

kubectl create -n dev -f ./manifests/hello-server.yaml
kubectl create -n prod -f ./manifests/hello-server.yaml
kubectl create -n test -f ./manifests/hello-server.yaml

kubectl get pods -l app=hello-server --all-namespaces
EOF_OWNER

# -----------------------------
# Step 3: Auditor validates permissions
# -----------------------------
gcloud compute ssh "$AUDITOR_INSTANCE" --zone "$ZONE" --project "$PROJECT_ID" --command="bash -s" <<'EOF_AUDITOR'
set -euo pipefail

sudo apt-get update -y
sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin

echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
source ~/.bashrc

gcloud container clusters get-credentials rbac-demo-cluster --zone "$(gcloud config get-value compute/zone)" --project "$(gcloud config get-value project)"

kubectl get pods -l app=hello-server --all-namespaces || true
kubectl get pods -l app=hello-server --namespace=dev
kubectl get pods -l app=hello-server --namespace=test || true
kubectl get pods -l app=hello-server --namespace=prod || true

kubectl create -n dev -f manifests/hello-server.yaml || true
kubectl delete deployment -n dev -l app=hello-server || true
EOF_AUDITOR

# -----------------------------
# Step 4: Deploy pod-labeler (initial)
# -----------------------------
gcloud compute ssh "$ADMIN_INSTANCE" --zone "$ZONE" --project "$PROJECT_ID" --command="bash -s" <<'EOF_POD'
set -euo pipefail

sudo apt-get update -y
sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin

echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
source ~/.bashrc

gcloud container clusters get-credentials rbac-demo-cluster --zone "$(gcloud config get-value compute/zone)" --project "$(gcloud config get-value project)"

kubectl apply -f manifests/pod-labeler.yaml
kubectl get pods -l app=pod-labeler
kubectl describe pod -l app=pod-labeler | tail -n 20
kubectl logs -l app=pod-labeler || true
EOF_POD

# -----------------------------
# Step 5: Apply fix 1 (serviceAccount)
# -----------------------------
gcloud compute ssh "$ADMIN_INSTANCE" --zone "$ZONE" --project "$PROJECT_ID" --command="bash -s" <<'EOF_FIX1'
set -euo pipefail

sudo apt-get update -y
sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin

echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
source ~/.bashrc

gcloud container clusters get-credentials rbac-demo-cluster --zone "$(gcloud config get-value compute/zone)" --project "$(gcloud config get-value project)"

kubectl apply -f manifests/pod-labeler-fix-1.yaml
EOF_FIX1

# -----------------------------
# Step 6: Apply fix 2 (patch permission)
# -----------------------------
gcloud compute ssh "$ADMIN_INSTANCE" --zone "$ZONE" --project "$PROJECT_ID" --command="bash -s" <<'EOF_FIX2'
set -euo pipefail

sudo apt-get update -y
sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin

echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
source ~/.bashrc

gcloud container clusters get-credentials rbac-demo-cluster --zone "$(gcloud config get-value compute/zone)" --project "$(gcloud config get-value project)"

kubectl apply -f manifests/pod-labeler-fix-2.yaml
kubectl delete pod -l app=pod-labeler
kubectl get pods --show-labels
EOF_FIX2

echo ">> LAB COMPLETE"
EOF

chmod +x gke_rbac_lab_full_dynamic.sh
./gke_rbac_lab_full_dynamic.sh
