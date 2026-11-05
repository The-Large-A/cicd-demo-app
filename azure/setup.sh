#!/usr/bin/env bash
# One-time Azure setup. Run in Azure Cloud Shell (Bash) from the repo root:
#   bash azure/setup.sh <your-laptop-public-ip>
# Creates a $15 budget alert, the resource group, ACR, a 1-node AKS cluster, the Jenkins VM
# (firewalled, shuts down nightly), the app namespace/quota/RBAC, and the files Jenkins needs.
# Safe to re-run: existing resources are kept and the output files are regenerated.
source "$(dirname "$0")/common.sh"

MY_IP="${1:-}"
require_ip "$MY_IP"

step "Subscription and region"
az account show --query "{subscription:name, user:user.name}" -o table
info "Region: $LOCATION   Resource group: $RG"
read -rp "Create the CI/CD resources here? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 1
mkdir -p "$OUT_DIR" && chmod 700 "$OUT_DIR"

step "Register the resource providers"
for provider in Microsoft.Compute Microsoft.Network Microsoft.ContainerService Microsoft.ContainerRegistry; do
  az provider register -n "$provider" --wait
  info "$provider"
done

# Stop before creating anything if the subscription would block a later step
bash "$REPO_ROOT/azure/preflight.sh"

step "Resource group"
az group create -n "$RG" -l "$LOCATION" -o none
info "$RG"

step "Monthly budget of $BUDGET_AMOUNT (billing currency) with email alerts at 50%, 80% and 100%"
EMAIL="$(az account show --query user.name -o tsv)"
cat > "$OUT_DIR/budget.json" <<EOF
{
  "properties": {
    "category": "Cost",
    "amount": $BUDGET_AMOUNT,
    "timeGrain": "Monthly",
    "timePeriod": { "startDate": "$(date -u +%Y-%m-01)T00:00:00Z" },
    "notifications": {
      "actual50":  { "enabled": true, "operator": "GreaterThanOrEqualTo", "threshold": 50,  "thresholdType": "Actual", "contactEmails": ["$EMAIL"] },
      "actual80":  { "enabled": true, "operator": "GreaterThanOrEqualTo", "threshold": 80,  "thresholdType": "Actual", "contactEmails": ["$EMAIL"] },
      "actual100": { "enabled": true, "operator": "GreaterThanOrEqualTo", "threshold": 100, "thresholdType": "Actual", "contactEmails": ["$EMAIL"] }
    }
  }
}
EOF
if az rest --method put -o none --body "@$OUT_DIR/budget.json" \
     --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Consumption/budgets/$BUDGET_NAME?api-version=2023-05-01"; then
  info "Alerts go to $EMAIL"
else
  info "WARNING: could not create the budget. Create one in the portal: Cost Management > Budgets."
fi

step "Container registry (ACR Basic)"
quietly az acr show -n "$ACR_NAME" ||
  az acr create -g "$RG" -n "$ACR_NAME" -l "$LOCATION" --sku Basic --admin-enabled true -o none
ACR_LOGIN_SERVER="$(az acr show -n "$ACR_NAME" --query loginServer -o tsv)"
info "$ACR_LOGIN_SERVER"

step "Kubernetes cluster (AKS free tier, 1 x $NODE_SIZE node, no monitoring add-on) - takes ~5-10 min"
quietly az aks show -g "$RG" -n "$AKS_NAME" ||
  az aks create -g "$RG" -n "$AKS_NAME" -l "$LOCATION" \
    --tier free \
    --node-count 1 \
    --node-vm-size "$NODE_SIZE" \
    --node-osdisk-type Managed \
    --node-osdisk-size "$DISK_GB" \
    --attach-acr "$ACR_NAME" \
    --auto-upgrade-channel none \
    --node-os-upgrade-channel None \
    --no-ssh-key \
    -o none
AKS_ID="$(az aks show -g "$RG" -n "$AKS_NAME" --query id -o tsv)"
info "$AKS_NAME is $(az aks show -g "$RG" -n "$AKS_NAME" --query powerState.code -o tsv)"

step "App namespace, resource quota and the Jenkins service account"
admin_kubectl apply -f "$REPO_ROOT/k8s/namespace.yaml" -f "$REPO_ROOT/k8s/quota.yaml" -f "$REPO_ROOT/k8s/rbac.yaml"
bash "$REPO_ROOT/azure/make-jenkins-kubeconfig.sh" "$ADMIN_KUBECONFIG" "$OUT_DIR/jenkins-kubeconfig.yaml"

step "Jenkins VM (Ubuntu 24.04, $VM_SIZE, static IP, firewall)"
[[ -f "$HOME/.ssh/id_rsa.pub" ]] || ssh-keygen -q -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
if quietly az vm show -g "$RG" -n "$VM_NAME"; then
  # Cloud Shell sessions can lose ~/.ssh, so make sure this session's key is on the VM
  az vm user update -g "$RG" -n "$VM_NAME" -u "$VM_USER" --ssh-key-value "$HOME/.ssh/id_rsa.pub" -o none
else
  quietly az network nsg show -g "$RG" -n "$NSG_NAME" || az network nsg create -g "$RG" -n "$NSG_NAME" -o none
  az vm create -g "$RG" -n "$VM_NAME" -l "$LOCATION" \
    --image Ubuntu2404 \
    --size "$VM_SIZE" \
    --admin-username "$VM_USER" \
    --ssh-key-values "$HOME/.ssh/id_rsa.pub" \
    --os-disk-size-gb "$DISK_GB" \
    --storage-sku StandardSSD_LRS \
    --public-ip-address pip-jenkins \
    --public-ip-sku Standard \
    --public-ip-address-allocation static \
    --nsg "$NSG_NAME" \
    -o none
fi
update_firewall "$MY_IP"
VM_IP="$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)"
info "Jenkins VM IP: $VM_IP"

step "Cost guards: VM shuts down at 23:00 IST; the VM may stop (only) the AKS cluster each night"
az vm auto-shutdown -g "$RG" -n "$VM_NAME" --time "$VM_SHUTDOWN_UTC" -o none
az vm identity assign -g "$RG" -n "$VM_NAME" --role Contributor --scope "$AKS_ID" -o none
info "Nightly shutdown at $VM_SHUTDOWN_UTC UTC; VM identity has Contributor on $AKS_NAME only"

step "Ansible in Cloud Shell (pinned versions from ansible/requirements.txt)"
[[ -x "$HOME/ansible-venv/bin/ansible-playbook" ]] || python3 -m venv "$HOME/ansible-venv"
"$HOME/ansible-venv/bin/pip" install -q -r "$REPO_ROOT/ansible/requirements.txt"
info "$("$HOME/ansible-venv/bin/ansible-playbook" --version | head -1)"

step "Write the outputs to $OUT_DIR"
cat > "$OUT_DIR/ansible-vars.yml" <<EOF
jenkins_vm_ip: $VM_IP
acr_login_server: $ACR_LOGIN_SERVER
aks_resource_id: $AKS_ID
EOF
(
  umask 077
  az acr credential show -n "$ACR_NAME" \
    --query "{username: username, password: passwords[0].value}" -o yaml > "$OUT_DIR/acr-credentials.yml"
)
rm -f "$OUT_DIR/budget.json"
ls -l "$OUT_DIR"

cat <<EOF

$(printf '\e[1;32m')Azure setup complete.$(printf '\e[0m')
Next steps:
  1. Configure Jenkins with Ansible:
       ~/ansible-venv/bin/ansible-playbook ansible/jenkins.yml -e @$OUT_DIR/ansible-vars.yml
  2. Open Jenkins at http://$VM_IP:8080 and add the credentials (see README.md):
       acr-credentials  <- $OUT_DIR/acr-credentials.yml   (cat it to see the values)
       aks-kubeconfig   <- $OUT_DIR/jenkins-kubeconfig.yaml (download it from Cloud Shell)
  3. Add the GitHub webhook: http://$VM_IP:8080/github-webhook/
  4. When you finish for the day: bash azure/stop.sh
EOF
