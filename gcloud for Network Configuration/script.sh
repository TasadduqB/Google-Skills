# Set strict error handling
set -e

echo "Starting GSP694 Automation..."

# ---------------------------------------------------------
# Task 1 & 2: View Networks and Subnets (Informational)
# ---------------------------------------------------------
echo "Listing Networks..."
gcloud compute networks list

echo "Listing Subnets..."
gcloud compute networks subnets list

# ---------------------------------------------------------
# Task 4: Creating firewall rules (labnet-allow-internal)
# ---------------------------------------------------------
echo "Creating 'labnet-allow-internal' firewall rule..."
gcloud compute firewall-rules create labnet-allow-internal \
	--network=labnet \
	--action=ALLOW \
	--rules=icmp,tcp:22 \
	--source-ranges=0.0.0.0/0

# ---------------------------------------------------------
# Task 5: Viewing firewall rules details (Informational)
# ---------------------------------------------------------
echo "Describing 'labnet-allow-internal' rule..."
gcloud compute firewall-rules describe labnet-allow-internal

# ---------------------------------------------------------
# Task 6: Create another firewall rule for privatenet (privatenet-deny)
# ---------------------------------------------------------
echo "Creating 'privatenet-deny' firewall rule..."
gcloud compute firewall-rules create privatenet-deny \
    --network=privatenet \
    --action=DENY \
    --rules=icmp,tcp:22 \
    --source-ranges=0.0.0.0/0

# ---------------------------------------------------------
# Task 7: List VM instances
# ---------------------------------------------------------
echo "Listing VM instances to verify setup..."
gcloud compute instances list

echo "---------------------------------------------------------"
echo "Lab automation complete! You can now click 'Check my progress'."
echo "To manually test connectivity (Task 8), use the External IPs listed above."
echo "---------------------------------------------------------"
