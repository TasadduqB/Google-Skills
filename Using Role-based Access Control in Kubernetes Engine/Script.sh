#!/bin/bash
set -e

echo "========================================"
echo "🔍 Discovering environment dynamically"
echo "========================================"

PROJECT_ID=$(gcloud config get-value project)

CLUSTER_NAME=$(gcloud container clusters list --format="value(name)" | head -n 1)
ZONE=$(gcloud container clusters list --format="value(location)" | head -n 1)
REGION=${ZONE%-*}

ADMIN_VM=$(gcloud compute instances list --filter="name~gke-tutorial-admin" --format="value(name)")
OWNER_VM=$(gcloud compute instances list --filter="name~gke-tutorial-owner" --format="value(name)")
AUDITOR_VM=$(gcloud compute instances list --filter="name~gke-tutorial-auditor" --format="value(name)")

echo "Project  : $PROJECT_ID"
echo "Cluster  : $CLUSTER_NAME"
echo "Zone     : $ZONE"
echo "Region   : $REGION"
echo "Admin VM : $ADMIN_VM"
echo "Owner VM : $OWNER_VM"
echo "Auditor VM: $AUDITOR_VM"

echo "========================================"
echo "⚙️ Setting compute defaults"
echo "========================================"

gcloud config set compute/region "$REGION"
gcloud config set compute/zone "$ZONE"

echo "========================================"
echo "🔐 TASK 2 – ADMIN: Apply RBAC"
echo "========================================"

gcloud compute ssh "$ADMIN_VM" --quiet << EOF
set -e

sudo apt-get update -y
sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin

echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
source ~/.bashrc

gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE

kubectl apply -f manifests/rbac.yaml

kubectl get namespaces
kubectl get clusterrolebinding owner-binding
kubectl get rolebinding auditor-binding -n dev
EOF

echo "========================================"
echo "👷 TASK 2 – OWNER: Create workloads"
echo "========================================"

gcloud compute ssh "$OWNER_VM" --quiet << EOF
set -e

sudo apt-get update -y
sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin
echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
source ~/.bashrc

gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE

kubectl create -n dev -f manifests/hello-server.yaml
kubectl create -n prod -f manifests/hello-server.yaml
kubectl create -n test -f manifests/hello-server.yaml

kubectl get pods -l app=hello-server --all-namespaces
EOF

echo "========================================"
echo "🔍 TASK 2 – AUDITOR: Permission validation"
echo "========================================"

gcloud compute ssh "$AUDITOR_VM" --quiet << EOF
set -e

sudo apt-get update -y
sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin
echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
source ~/.bashrc

gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE

kubectl get pods -l app=hello-server --all-namespaces || true
kubectl get pods -n dev -l app=hello-server
kubectl get pods -n test -l app=hello-server || true
kubectl get pods -n prod -l app=hello-server || true

kubectl create -n dev -f manifests/hello-server.yaml || true
kubectl delete deployment -n dev -l app=hello-server || true
EOF

echo "========================================"
echo "🤖 TASK 3 – ADMIN: Pod Labeler Debugging"
echo "========================================"

gcloud compute ssh "$ADMIN_VM" --quiet << EOF
set -e
source ~/.bashrc

kubectl apply -f manifests/pod-labeler.yaml

kubectl get pods -l app=pod-labeler || true
kubectl logs -l app=pod-labeler || true

kubectl apply -f manifests/pod-labeler-fix-1.yaml
kubectl apply -f manifests/pod-labeler-fix-2.yaml

kubectl delete pod -l app=pod-labeler
sleep 10

kubectl get pods -l app=pod-labeler
kubectl get pods --show-labels
kubectl logs -l app=pod-labeler
EOF

echo "========================================"
echo "✅ LAB COMPLETED – RBAC VERIFIED"
echo "========================================"
