#!/usr/bin/env bash
# Settings and helpers shared by the Azure scripts. Run the scripts in Azure Cloud Shell (Bash).
# shellcheck disable=SC2034  # settings are used by the scripts that source this file
set -euo pipefail

RG="rg-cicd-demo"
LOCATION="${LOCATION:-eastasia}"       # allowed for this Azure for Students subscription; override: LOCATION=<region>
AKS_NAME="aks-cicd-demo"
VM_NAME="vm-jenkins"
VM_USER="azureuser"
NSG_NAME="nsg-jenkins"
# 2 vCPU / 4 GB: the smallest size AKS accepts for its system node. Student subscriptions
# only allow the newer B-series v2 sizes, and B2als_v2 is the cheapest of those that fits.
NODE_SIZE="Standard_B2als_v2"
VM_SIZE="Standard_B2als_v2"
DISK_GB=30
NAMESPACE="cicd-demo"
APP_NAME="cicd-demo-app"
BUDGET_NAME="budget-cicd-demo"
# In the subscription's billing currency: this Azure for Students account bills in INR,
# so 1300 is about \$15. (Check with: bash azure/check.sh, which prints the currency.)
BUDGET_AMOUNT=1300
VM_SHUTDOWN_UTC="1730"                # 23:00 IST
KEEP_IMAGES=5

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$HOME/cicd-outputs"
ADMIN_KUBECONFIG="$OUT_DIR/admin-kubeconfig"

SUB_ID="$(az account show --query id -o tsv)"
# ACR names must be globally unique, so derive one from the subscription id
ACR_NAME="acrcicd$(echo "$SUB_ID" | tr -d '-' | cut -c1-10)"

step() { printf '\n\e[1;33m# %s\e[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
quietly() { "$@" >/dev/null 2>&1; }

# Result helpers for the read-only checks (preflight.sh, check.sh)
FAILS=0
WARNS=0
pass() { printf '  \e[32mPASS\e[0m  %s\n' "$*"; }
warn() { printf '  \e[33mWARN\e[0m  %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  \e[31mFAIL\e[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); }

require_ip() {
  if [[ ! "${1:-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "Pass your laptop's public IPv4 address (open https://api.ipify.org in your browser)." >&2
    exit 1
  fi
}

# Create the NSG rule, or update it if it already exists
nsg_rule() {
  local name="$1"; shift
  local action=create
  quietly az network nsg rule show -g "$RG" --nsg-name "$NSG_NAME" -n "$name" && action=update
  az network nsg rule "$action" -g "$RG" --nsg-name "$NSG_NAME" -n "$name" \
    --access Allow --protocol Tcp --direction Inbound "$@" -o none
}

# SSH only from this Cloud Shell session; Jenkins only from your IP and GitHub's webhook servers
update_firewall() {
  local my_ip="$1" shell_ip
  local -a hook_ips
  shell_ip="$(curl -fsS https://api.ipify.org)"
  mapfile -t hook_ips < <(curl -fsS https://api.github.com/meta | jq -r '.hooks[] | select(contains(":") | not)')
  nsg_rule allow-ssh-cloudshell --priority 100 --destination-port-ranges 22 --source-address-prefixes "$shell_ip"
  nsg_rule allow-jenkins --priority 110 --destination-port-ranges 8080 \
    --source-address-prefixes "$my_ip" "${hook_ips[@]}"
  info "SSH  (22)   allowed from this Cloud Shell: $shell_ip"
  info "Jenkins (8080) allowed from you ($my_ip) and GitHub webhooks (${#hook_ips[@]} ranges)"
}

admin_kubectl() {
  mkdir -p "$OUT_DIR"
  az aks get-credentials -g "$RG" -n "$AKS_NAME" --admin --file "$ADMIN_KUBECONFIG" --overwrite-existing -o none
  chmod 600 "$ADMIN_KUBECONFIG"
  kubectl --kubeconfig "$ADMIN_KUBECONFIG" "$@"
}
