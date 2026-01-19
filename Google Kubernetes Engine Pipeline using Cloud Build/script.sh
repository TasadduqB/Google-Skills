cat << 'EOF' > run_lab.sh
#!/bin/bash
set -e

# ==============================================================================
# GSP1077: Google Kubernetes Engine Pipeline using Cloud Build
# AUTOMATION SCRIPT
# ==============================================================================

# --- Configuration ---
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
export USER_EMAIL=$(gcloud auth list --filter=status:ACTIVE --format='value(account)')

# Auto-detect region from the zone (e.g., us-east1-b -> us-east1)
# We check if ZONE is set; if not, we try to detect or default
if [ -z "$ZONE" ]; then
    export ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
fi
if [ -z "$ZONE" ] || [ "$ZONE" == "(unset)" ]; then
    export ZONE="us-east1-b" # Default fallback
fi
export REGION="${ZONE%-*}"

# Check GitHub Auth
if ! gh auth status >/dev/null 2>&1; then
    echo "Error: You must run 'gh auth login' first!"
    exit 1
fi
export GITHUB_USERNAME=$(gh api user -q ".login")

echo "--- Setting up Environment ($REGION) ---"
gcloud config set compute/region $REGION
gcloud services enable container.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com containeranalysis.googleapis.com

# Create Artifact Registry
echo "--- Creating Artifact Registry ---"
gcloud artifacts repositories create my-repository --repository-format=docker --location=$REGION || true

# Create GKE Cluster
echo "--- Creating GKE Cluster (this runs in background) ---"
gcloud container clusters create hello-cloudbuild --num-nodes 1 --region $REGION --async

# Create GitHub Repos (Ignoring errors if they exist)
echo "--- Creating GitHub Repositories ---"
gh repo create hello-cloudbuild-app --private || true
gh repo create hello-cloudbuild-env --private || true

# Setup App Repo
echo "--- Setting up App Repository ---"
cd ~
rm -rf hello-cloudbuild-app
mkdir hello-cloudbuild-app
gcloud storage cp -r gs://spls/gsp1077/gke-gitops-tutorial-cloudbuild/* hello-cloudbuild-app
cd hello-cloudbuild-app

# Fix Regions in files
sed -i "s/us-central1/$REGION/g" cloudbuild.yaml
sed -i "s/us-central1/$REGION/g" cloudbuild-delivery.yaml
sed -i "s/us-central1/$REGION/g" cloudbuild-trigger-cd.yaml
sed -i "s/us-central1/$REGION/g" kubernetes.yaml.tpl

# Initialize Git
git init
git config --global user.email "$USER_EMAIL"
git config --global user.name "$GITHUB_USERNAME"
git config credential.helper gcloud.sh
git remote add google https://github.com/${GITHUB_USERNAME}/hello-cloudbuild-app
git branch -m master
git add .
git commit -m "initial commit"

# Wait for Cluster (needed for builds)
echo "--- Waiting for GKE Cluster to be ready... ---"
until gcloud container clusters describe hello-cloudbuild --region $REGION --format='value(status)' | grep -q "RUNNING"; do sleep 10; echo -n "."; done
echo ""

# Build Initial Image
echo "--- Building Initial Image ---"
COMMIT_ID="$(git rev-parse --short=7 HEAD)"
gcloud builds submit --tag="${REGION}-docker.pkg.dev/${PROJECT_ID}/my-repository/hello-cloudbuild:${COMMIT_ID}" .

# --- PAUSE FOR TRIGGER 1 ---
echo "================================================================"
echo "ACTION REQUIRED: Create the CI Trigger in Cloud Console"
echo "1. Go to Cloud Build > Triggers > Create Trigger"
echo "2. Name: hello-cloudbuild"
echo "3. Region: $REGION"
echo "4. Event: Push to a branch"
echo "5. Source: Connect New Repository -> GitHub (Cloud Build GitHub App)"
echo "   (Authorize access to your GitHub account and install the app if needed)"
echo "   Select repo: hello-cloudbuild-app"
echo "6. Branch: .*"
echo "7. Configuration: Cloud Build configuration file (cloudbuild.yaml)"
echo "8. Click CREATE"
echo "================================================================"
read -p "Press [Enter] once you have created the 'hello-cloudbuild' trigger..."

# Push to trigger CI
git push google master --force

# SSH Keys and Secrets
echo "--- Setting up SSH Keys and Secrets ---"
cd ~
mkdir -p workingdir
cd workingdir
# Generate new key or overwrite existing
ssh-keygen -t rsa -b 4096 -N '' -f id_github -C "$USER_EMAIL" <<< y

# Secret Manager
gcloud secrets create ssh_key_secret --replication-policy="automatic" || true
gcloud secrets versions add ssh_key_secret --data-file=id_github

gcloud projects add-iam-policy-binding ${PROJECT_NUMBER} \
--member=serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com \
--role=roles/secretmanager.secretAccessor

# Add Deploy Key to GitHub Env Repo
echo "--- Adding Deploy Key to GitHub 'hello-cloudbuild-env' ---"
gh repo deploy-key add id_github.pub --repo "${GITHUB_USERNAME}/hello-cloudbuild-env" --allow-write --title "SSH_KEY"

# Setup CD Pipeline / Env Repo
echo "--- Setting up Env Repository ---"
gcloud projects add-iam-policy-binding ${PROJECT_NUMBER} \
--member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com \
--role=roles/container.developer

cd ~
rm -rf hello-cloudbuild-env
mkdir hello-cloudbuild-env
gcloud storage cp -r gs://spls/gsp1077/gke-gitops-tutorial-cloudbuild/* hello-cloudbuild-env
cd hello-cloudbuild-env

# Fix Regions
sed -i "s/us-central1/$REGION/g" cloudbuild.yaml
sed -i "s/us-central1/$REGION/g" cloudbuild-delivery.yaml
sed -i "s/us-central1/$REGION/g" cloudbuild-trigger-cd.yaml
sed -i "s/us-central1/$REGION/g" kubernetes.yaml.tpl

# Known Hosts
ssh-keyscan -t rsa github.com > known_hosts.github
chmod +x known_hosts.github

# Git Init Env
git init
git remote add google https://github.com/${GITHUB_USERNAME}/hello-cloudbuild-env
git branch -m master
git add .
git commit -m "initial commit"
git push google master --force

git checkout -b production
git checkout -b candidate
git push google production --force
git push google candidate --force

# Write CD cloudbuild.yaml
cat <<YAML > cloudbuild.yaml
steps:
- name: 'gcr.io/cloud-builders/kubectl'
  id: Deploy
  args:
  - 'apply'
  - '-f'
  - 'kubernetes.yaml'
  env:
  - 'CLOUDSDK_COMPUTE_REGION=$REGION'
  - 'CLOUDSDK_CONTAINER_CLUSTER=hello-cloudbuild'
- name: 'gcr.io/cloud-builders/git'
  secretEnv: ['SSH_KEY']
  entrypoint: 'bash'
  args:
  - -c
  - |
    echo "\$\$SSH_KEY" >> /root/.ssh/id_rsa
    chmod 400 /root/.ssh/id_rsa
    cp known_hosts.github /root/.ssh/known_hosts
  volumes:
  - name: 'ssh'
    path: /root/.ssh
- name: 'gcr.io/cloud-builders/git'
  args:
  - clone
  - --recurse-submodules
  - git@github.com:${GITHUB_USERNAME}/hello-cloudbuild-env.git
  volumes:
  - name: ssh
    path: /root/.ssh
- name: 'gcr.io/cloud-builders/gcloud'
  id: Copy to production branch
  entrypoint: /bin/sh
  args:
  - '-c'
  - |
    set -x && \\
    cd hello-cloudbuild-env && \\
    git config user.email \$(gcloud auth list --filter=status:ACTIVE --format='value(account)') && \\
    sed "s/GOOGLE_CLOUD_PROJECT/${PROJECT_ID}/g" kubernetes.yaml.tpl | \\
    git fetch origin production && \\
    git checkout production && \\
    git checkout \$COMMIT_SHA kubernetes.yaml && \\
    git commit -m "Manifest from commit \$COMMIT_SHA
    \$(git log --format=%B -n 1 \$COMMIT_SHA)" && \\
    git push origin production
  volumes:
  - name: ssh
    path: /root/.ssh

availableSecrets:
  secretManager:
  - versionName: projects/${PROJECT_NUMBER}/secrets/ssh_key_secret/versions/1
    env: 'SSH_KEY'

options:
  logging: CLOUD_LOGGING_ONLY
YAML

git add .
git commit -m "Create cloudbuild.yaml for deployment"
git push google candidate

# --- PAUSE FOR TRIGGER 2 ---
echo "================================================================"
echo "ACTION REQUIRED: Create the CD Trigger in Cloud Console"
echo "1. Go to Cloud Build > Triggers > Create Trigger"
echo "2. Name: hello-cloudbuild-deploy"
echo "3. Region: $REGION"
echo "4. Event: Push to a branch"
echo "5. Source: Select repo 'hello-cloudbuild-env'"
echo "6. Branch: ^candidate$"
echo "7. Configuration: Cloud Build configuration file (cloudbuild.yaml)"
echo "8. Click CREATE"
echo "================================================================"
read -p "Press [Enter] once you have created the 'hello-cloudbuild-deploy' trigger..."

# Link CI to CD
echo "--- Linking CI pipeline to CD pipeline ---"
cd ~/hello-cloudbuild-app
ssh-keyscan -t rsa github.com > known_hosts.github
chmod +x known_hosts.github
git add .
git commit -m "Adding known_host file."
git push google master

# Update App cloudbuild.yaml
cat <<YAML > cloudbuild.yaml
steps:
- name: 'python:3.7-slim'
  id: Test
  entrypoint: /bin/sh
  args:
  - -c
  - 'pip install flask && python test_app.py -v'
- name: 'gcr.io/cloud-builders/docker'
  id: Build
  args:
  - 'build'
  - '-t'
  - '$REGION-docker.pkg.dev/$PROJECT_ID/my-repository/hello-cloudbuild:\$SHORT_SHA'
  - '.'
- name: 'gcr.io/cloud-builders/docker'
  id: Push
  args:
  - 'push'
  - '$REGION-docker.pkg.dev/$PROJECT_ID/my-repository/hello-cloudbuild:\$SHORT_SHA'
- name: 'gcr.io/cloud-builders/git'
  secretEnv: ['SSH_KEY']
  entrypoint: 'bash'
  args:
  - -c
  - |
    echo "\$\$SSH_KEY" >> /root/.ssh/id_rsa
    chmod 400 /root/.ssh/id_rsa
    cp known_hosts.github /root/.ssh/known_hosts
  volumes:
  - name: 'ssh'
    path: /root/.ssh
- name: 'gcr.io/cloud-builders/git'
  args:
  - clone
  - --recurse-submodules
  - git@github.com:${GITHUB_USERNAME}/hello-cloudbuild-env.git
  volumes:
  - name: ssh
    path: /root/.ssh
- name: 'gcr.io/cloud-builders/gcloud'
  id: Change directory
  entrypoint: /bin/sh
  args:
  - '-c'
  - |
    cd hello-cloudbuild-env && \\
    git checkout candidate && \\
    git config user.email \$(gcloud auth list --filter=status:ACTIVE --format='value(account)')
  volumes:
  - name: ssh
    path: /root/.ssh
- name: 'gcr.io/cloud-builders/gcloud'
  id: Generate manifest
  entrypoint: /bin/sh
  args:
  - '-c'
  - |
     sed "s/GOOGLE_CLOUD_PROJECT/${PROJECT_ID}/g" kubernetes.yaml.tpl | \\
     sed "s/COMMIT_SHA/\${SHORT_SHA}/g" > hello-cloudbuild-env/kubernetes.yaml
  volumes:
  - name: ssh
    path: /root/.ssh
- name: 'gcr.io/cloud-builders/gcloud'
  id: Push manifest
  entrypoint: /bin/sh
  args:
  - '-c'
  - |
    set -x && \\
    cd hello-cloudbuild-env && \\
    git add kubernetes.yaml && \\
    git commit -m "Deploying image $REGION-docker.pkg.dev/$PROJECT_ID/my-repository/hello-cloudbuild:\${SHORT_SHA}
    Built from commit \${COMMIT_SHA} of repository hello-cloudbuild-app
    Author: \$(git log --format='%an <%ae>' -n 1 HEAD)" && \\
    git push origin candidate
  volumes:
  - name: ssh
    path: /root/.ssh

availableSecrets:
  secretManager:
  - versionName: projects/${PROJECT_NUMBER}/secrets/ssh_key_secret/versions/1
    env: 'SSH_KEY'

options:
  logging: CLOUD_LOGGING_ONLY
YAML

git add cloudbuild.yaml
git commit -m "Trigger CD pipeline"
git push google master

echo "--- Final Test: Updating App to 'Hello Cloud Build' ---"
sed -i 's/Hello World/Hello Cloud Build/g' app.py
sed -i 's/Hello World/Hello Cloud Build/g' test_app.py
git add app.py test_app.py
git commit -m "Hello Cloud Build"
git push google master

echo "======================================================"
echo "Script Complete. Check Cloud Build History for progress."
echo "Once the pipeline finishes, check the Service IP in GKE."
echo "======================================================"
EOF

chmod +x run_lab.sh
./run_lab.sh
