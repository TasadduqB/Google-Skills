cat << 'EOF' > private_cluster_lab.sh
#!/bin/bash

# ==============================================================================
# GSP178: Setting up a Private Kubernetes Cluster
# FULLY AUTOMATED DYNAMIC SOLUTION
# ==============================================================================

# Fail on error
set -e

echo "========================================================"
echo "    INITIALIZING LAB AUTOMATION"
echo "========================================================"

# 1. Auto-Detect Project ID
export PROJECT_ID=$(gcloud config get-value project)

# 2. Auto-Detect Assigned Zone and Region
# Attempt 1: Check gcloud config
export ZONE=$(gcloud config get-value compute/zone 2>/dev/null)

# Attempt 2: Check Metadata (common in Qwiklabs)
if [ -z "$ZONE" ] || [ "$ZONE" == "(unset)" ]; then
  echo "Zone not in config. Checking project metadata..."
  ZONE=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items.google-compute-default-zone)" 2>/dev/null)
  ZONE=${ZONE##*/}
fi

# Attempt 3: Default fallback if detection fails
if [ -z "$ZONE" ] || [ "$ZONE" == "(unset)" ]; then
  echo "Zone detection failed. Defaulting to us-central1-a..."
  ZONE="us-central1-a"
fi

# Derive Region from Zone (e.g., us-central1-a -> us-central1)
export REGION=${ZONE%-*}

# 3. Set Config
gcloud config set compute/zone $ZONE

echo "--------------------------------------------------------"
echo "Project:  $PROJECT_ID"
echo "Region:   $REGION"
echo "Zone:     $ZONE"
echo "--------------------------------------------------------"

# ==============================================================================
# Task 2: Creating a private cluster
# ==============================================================================
echo "[Task 2] Creating 'private-cluster' (Approx 5-7 mins)..."


# Check if cluster exists before creating
if ! gcloud container clusters describe private-cluster --zone $ZONE > /dev/null 2>&1; then
    gcloud beta container clusters create private-cluster \
        --enable-private-nodes \
        --master-ipv4-cidr 172.16.0.16/28 \
        --enable-ip-alias \
        --create-subnetwork "" \
        --region $ZONE \
        --quiet
else
    echo "Cluster 'private-cluster' already exists. Skipping creation."
fi

# ==============================================================================
# Task 3: View subnet and secondary address ranges
# ==============================================================================
echo "[Task 3] Inspecting Subnets..."

# Dynamically find the subnet created by the cluster
SUBNET_NAME=$(gcloud compute networks subnets list --network default --filter="name ~ gke-private-cluster-subnet" --format="value(name)" | head -n 1)

if [ -n "$SUBNET_NAME" ]; then
    echo "Found Subnet: $SUBNET_NAME"
    gcloud compute networks subnets describe $SUBNET_NAME --region=$REGION
else
    echo "Warning: Could not auto-detect subnet. Proceeding..."
fi

# ==============================================================================
# Task 4: Enable master authorized networks
# ==============================================================================
echo "[Task 4] Setting up Source Instance & Authorization..."

# 1. Create Source Instance (Jump Host)
if ! gcloud compute instances describe source-instance --zone $ZONE > /dev/null 2>&1; then
    gcloud compute instances create source-instance \
        --zone=$ZONE \
        --scopes 'https://www.googleapis.com/auth/cloud-platform' \
        --quiet
else
    echo "Instance 'source-instance' already exists."
fi

# 2. Get NAT IP
NAT_IP=$(gcloud compute instances describe source-instance --zone=$ZONE --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
echo "Detected Jump Host IP: $NAT_IP"

# 3. Authorize Network
echo "Authorizing $NAT_IP/32 on cluster..."
gcloud container clusters update private-cluster \
    --enable-master-authorized-networks \
    --master-authorized-networks $NAT_IP/32 \
    --region $ZONE \
    --quiet

# 4. SSH and Verify
echo "Verifying connectivity via SSH..."
# We use a heredoc to run commands inside the VM
gcloud compute ssh source-instance --zone=$ZONE --quiet --command "
    sudo apt-get update -y
    sudo apt-get install -y kubectl google-cloud-sdk-gke-gcloud-auth-plugin
    export ZONE=$ZONE
    gcloud container clusters get-credentials private-cluster --zone=$ZONE
    echo '--- Checking Nodes (Internal IP Verification) ---'
    kubectl get nodes --output yaml | grep -A4 addresses
"

# ==============================================================================
# Task 5: Clean Up (Delete First Cluster)
# ==============================================================================
echo "[Task 5] Deleting 'private-cluster'..."
gcloud container clusters delete private-cluster --zone=$ZONE --quiet || echo "Cluster already deleted."

# ==============================================================================
# Task 6: Create a private cluster with custom subnetwork
# ==============================================================================
echo "[Task 6] Creating Custom Subnetwork..."

if ! gcloud compute networks subnets describe my-subnet --region $REGION > /dev/null 2>&1; then
    gcloud compute networks subnets create my-subnet \
        --network default \
        --range 10.0.4.0/22 \
        --enable-private-ip-google-access \
        --region=$REGION \
        --secondary-range my-svc-range=10.0.32.0/20,my-pod-range=10.4.0.0/14 \
        --quiet
else
    echo "Subnet 'my-subnet' already exists."
fi

echo "Creating 'private-cluster2' (Approx 5-7 mins)..."
if ! gcloud container clusters describe private-cluster2 --zone $ZONE > /dev/null 2>&1; then
    gcloud beta container clusters create private-cluster2 \
        --enable-private-nodes \
        --enable-ip-alias \
        --master-ipv4-cidr 172.16.0.32/28 \
        --subnetwork my-subnet \
        --services-secondary-range-name my-svc-range \
        --cluster-secondary-range-name my-pod-range \
        --zone=$ZONE \
        --quiet
else
    echo "Cluster 'private-cluster2' already exists."
fi

echo "Authorizing Jump Host IP ($NAT_IP) on new cluster..."
gcloud container clusters update private-cluster2 \
    --enable-master-authorized-networks \
    --zone=$ZONE \
    --master-authorized-networks $NAT_IP/32 \
    --quiet

echo "Verifying connectivity to private-cluster2..."
gcloud compute ssh source-instance --zone=$ZONE --quiet --command "
    export ZONE=$ZONE
    gcloud container clusters get-credentials private-cluster2 --zone=$ZONE
    echo '--- Checking Custom Subnet Nodes ---'
    kubectl get nodes --output yaml | grep -A4 addresses
"

echo "========================================================"
echo "LAB COMPLETE - ALL TASKS FINISHED"
echo "========================================================"
EOF

chmod +x private_cluster_lab.sh
./private_cluster_lab.sh
