#!/bin/bash
set -e

PROJECT_ID=$(gcloud config get-value project)
CLUSTER_NAME=$(gcloud container clusters list --format="value(name)" | head -n 1)
ZONE=$(gcloud container clusters list --format="value(location)" | head -n 1)
REGION=${ZONE%-*}

ADMIN_VM=$(gcloud compute instances list --filter="name~gke-tutorial-admin" --format="value(name)")
OWNER_VM=$(gcloud compute instances list --filter="name~gke-tutorial-owner" --format="value(name)")
AUDITOR_VM=$(gcloud compute instances list --filter="name~gke-tutorial-auditor" --format="value(name)")

gcloud config set compute/region "$REGION"
gcloud config set compute/zone "$ZONE"

gcloud compute ssh "$ADMIN_VM" --quiet << EOF
sudo apt-get update -y
sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin
echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
source ~/.bashrc
gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE
kubectl apply -f manifests/rbac.yaml
EOF

gcloud compute ssh "$OWNER_VM" --quiet << EOF
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

gcloud compute ssh "$AUDITOR_VM" --quiet << EOF
sudo apt-get update -y
sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin
echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
source ~/.bashrc
gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE
kubectl get pods --all-namespaces || true
kubectl get pods -n dev || true
kubectl get pods -n test || true
kubectl get pods -n prod || true
kubectl create -n dev -f manifests/hello-server.yaml || true
kubectl delete deployment -n dev -l app=hello-server || true
EOF

gcloud compute ssh "$ADMIN_VM" --quiet << EOF
source ~/.bashrc
kubectl apply -f manifests/pod-labeler.yaml
kubectl apply -f manifests/pod-labeler-fix-1.yaml
kubectl apply -f manifests/pod-labeler-fix-2.yaml
kubectl delete pod -l app=pod-labeler
sleep 10
kubectl get pods --show-labels
kubectl logs -l app=pod-labeler
EOF

echo "LAB COMPLETE"
