cat << 'EOF' > robust_debug_lab.sh
#!/bin/bash
# ==============================================================================
# GSP736: Debug Apps on Google Kubernetes Engine
# ROBUST FIX: Uses 'Update' if metric exists to solve conflicts
# ==============================================================================

# Fail on error
set -e

echo "========================================================"
echo "   STARTING LAB AUTOMATION"
echo "========================================================"

# --- 1. Dynamic Configuration ---
export PROJECT_ID=$(gcloud config get-value project)

# Auto-detect Zone
echo "Detecting Zone..."
export ZONE=$(gcloud container clusters list --filter="name:central" --format="value(location)" 2>/dev/null)
if [ -z "$ZONE" ]; then
    echo "Zone detection failed. Defaulting to us-central1-c"
    export ZONE=us-central1-c
fi

echo "Project: $PROJECT_ID"
echo "Zone:    $ZONE"
gcloud config set compute/zone $ZONE

# --- 2. Cluster Connection ---
echo "--- Task 1: Connecting to Cluster ---"
echo "Waiting for cluster 'central' to be ready..."
until gcloud container clusters list --filter="name:central AND status=RUNNING" --format="value(name)" | grep -q "central"; do
    echo -n "."
    sleep 10
done
echo ""
gcloud container clusters get-credentials central --zone $ZONE

# --- 3. Deploy Application ---
echo "--- Task 2: Deploying Microservices Demo ---"
cd ~
rm -rf microservices-demo
git clone https://github.com/xiangshen-dk/microservices-demo.git
cd microservices-demo

kubectl apply -f release/kubernetes-manifests.yaml

echo "Waiting for frontend to be ready (approx 2 mins)..."
kubectl wait --for=condition=Ready pod -l app=frontend --timeout=300s || true

# --- 4. Logs-Based Metric (UPSERT LOGIC) ---
echo "--- Task 4: Configuring Logs-Based Metric 'Error_Rate_SLI' ---"

METRIC_NAME="Error_Rate_SLI"
FILTER='resource.type="k8s_container" AND severity=ERROR AND labels."k8s-pod/app": "recommendationservice"'
DESCRIPTION="Metric for lab"

# Check if metric exists
if gcloud logging metrics describe $METRIC_NAME >/dev/null 2>&1; then
    echo "Metric $METRIC_NAME exists. Updating it to match lab requirements..."
    gcloud logging metrics update $METRIC_NAME \
        --description="$DESCRIPTION" \
        --log-filter="$FILTER"
else
    echo "Metric $METRIC_NAME does not exist. Creating it..."
    gcloud logging metrics create $METRIC_NAME \
        --description="$DESCRIPTION" \
        --log-filter="$FILTER"
fi

echo "Metric configuration applied."

# --- 5. Alerting Policy ---
echo "--- Task 5: Creating Alerting Policy ---"

cat <<JSON > alert_policy.json
{
  "displayName": "Error Rate SLI",
  "conditions": [
    {
      "displayName": "Log match condition",
      "conditionThreshold": {
        "filter": "resource.type = \"k8s_container\" AND metric.type = \"logging.googleapis.com/user/Error_Rate_SLI\"",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "crossSeriesReducer": "REDUCE_SUM",
            "perSeriesAligner": "ALIGN_RATE"
          }
        ],
        "comparison": "COMPARISON_GT",
        "duration": "0s",
        "trigger": { "count": 1 },
        "thresholdValue": 0.5
      }
    }
  ],
  "combiner": "OR",
  "enabled": true
}
JSON

gcloud alpha monitoring policies create --policy-from-file="alert_policy.json"
echo "Alert Policy created."

# --- 6. Fix Application ---
echo "--- Task 6: Fixing the Application Issue ---"
echo "Disabling catalog reloading in manifest..."

LINE_NUM=$(grep -n "name: ENABLE_RELOAD" release/kubernetes-manifests.yaml | cut -d: -f1)
if [ ! -z "$LINE_NUM" ]; then
    NEXT_LINE=$((LINE_NUM + 1))
    sed -i "${LINE_NUM},${NEXT_LINE}d" release/kubernetes-manifests.yaml
    echo "Removed ENABLE_RELOAD variable."
else
    echo "ENABLE_RELOAD not found (might already be fixed)."
fi

kubectl apply -f release/kubernetes-manifests.yaml

echo "Waiting for productcatalogservice rollout..."
kubectl rollout status deployment/productcatalogservice --timeout=180s

echo "========================================================"
echo "   LAB COMPLETE"
echo "   You can now verify all tasks in the lab window."
echo "========================================================"
EOF

chmod +x robust_debug_lab.sh
./robust_debug_lab.sh
