#!/usr/bin/env bash
# Read-only check that this subscription allows everything setup.sh will create.
# Creates nothing. Run in Azure Cloud Shell:  bash azure/preflight.sh
# setup.sh runs it first and stops if anything FAILs.
source "$(dirname "$0")/common.sh"

FAILS=0
WARNS=0
pass() { printf '  \e[32mPASS\e[0m  %s\n' "$*"; }
warn() { printf '  \e[33mWARN\e[0m  %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  \e[31mFAIL\e[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# Resources that already exist (from an earlier run) need no new quota
AKS_EXISTS=false; VM_EXISTS=false
quietly az aks show -g "$RG" -n "$AKS_NAME" && AKS_EXISTS=true
quietly az vm show -g "$RG" -n "$VM_NAME" && VM_EXISTS=true

step "Subscription and permissions"
account="$(az account show -o json)"
info "Subscription: $(jq -r .name <<< "$account")  ($(jq -r '.subscriptionPolicies.quotaId // "unknown offer"' <<< "$account"))"
info "Signed in as: $(jq -r .user.name <<< "$account")"
user_id="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
roles=""
if [[ -n "$user_id" ]]; then
  roles="$(az role assignment list --assignee "$user_id" --scope "/subscriptions/$SUB_ID" --include-inherited \
    --query "[].roleDefinitionName" -o tsv 2>/dev/null | sort -u | tr '\n' ' ' || true)"
fi
if [[ " $roles " == *" Owner "* ]]; then
  pass "You are Owner (needed to let AKS pull from ACR and to give the VM its identity)"
elif [[ -n "$roles" ]]; then
  fail "Your roles are: $roles- setup needs Owner on the subscription"
else
  warn "Could not read your role assignments; setup needs Owner on the subscription"
fi

step "Azure Policy assignments (how the subscription is restricted)"
policies="$(az policy assignment list --disable-scope-strict-match -o json 2>/dev/null || echo '[]')"
if [[ "$(jq length <<< "$policies")" == "0" ]]; then
  info "(none)"
fi
jq -r '.[] | "  - " + (.displayName // .name)' <<< "$policies"

allowed_locations="$(jq -r '[.[].parameters.listOfAllowedLocations.value[]?] | unique | join(" ")' <<< "$policies")"
if [[ -z "$allowed_locations" ]]; then
  pass "No region restriction"
elif [[ " $allowed_locations " == *" $LOCATION "* ]]; then
  pass "Region $LOCATION is allowed (allowed: $allowed_locations)"
else
  fail "Region $LOCATION is not allowed. Allowed: $allowed_locations"
fi

allowed_skus="$(jq -r '[.[].parameters.listOfAllowedSKUs.value[]?] | map(ascii_downcase) | unique | join(" ")' <<< "$policies")"
for size in $(printf '%s\n' "$NODE_SIZE" "$VM_SIZE" | sort -u); do
  lower="$(tr '[:upper:]' '[:lower:]' <<< "$size")"
  if [[ -n "$allowed_skus" && " $allowed_skus " != *" $lower "* ]]; then
    fail "Policy does not allow VM size $size"
  fi
done

# Resource types setup.sh creates (directly or through AKS / az vm create)
needed_types=(
  Microsoft.ContainerService/managedClusters Microsoft.ContainerRegistry/registries
  Microsoft.Compute/virtualMachines Microsoft.Compute/disks Microsoft.Network/publicIPAddresses
  Microsoft.Network/networkSecurityGroups Microsoft.Network/virtualNetworks
  Microsoft.Network/networkInterfaces Microsoft.Network/loadBalancers
  Microsoft.ManagedIdentity/userAssignedIdentities Microsoft.DevTestLab/schedules
)
denied_types="$(jq -r '[.[].parameters.listOfResourceTypesNotAllowed.value[]?] | map(ascii_downcase) | join(" ")' <<< "$policies")"
only_types="$(jq -r '[.[].parameters.listOfResourceTypesAllowed.value[]?] | map(ascii_downcase) | join(" ")' <<< "$policies")"
type_problem=false
for t in "${needed_types[@]}"; do
  lt="$(tr '[:upper:]' '[:lower:]' <<< "$t")"
  if [[ " $denied_types " == *" $lt "* ]] || [[ -n "$only_types" && " $only_types " != *" $lt "* ]]; then
    fail "Policy blocks resource type $t"
    type_problem=true
  fi
done
$type_problem || pass "No policy blocks the ${#needed_types[@]} resource types setup creates"

step "VM size $NODE_SIZE (AKS node) and $VM_SIZE (Jenkins VM)"
declare -A need=([cores]=0)
for machine in "AKS node" "Jenkins VM"; do
  if [[ "$machine" == "AKS node" ]]; then size="$NODE_SIZE"; exists=$AKS_EXISTS; else size="$VM_SIZE"; exists=$VM_EXISTS; fi
  sku="$(az vm list-skus -l "$LOCATION" --size "$size" --resource-type virtualMachines -o json |
    jq -c --arg s "$size" '[.[] | select(.name == $s)][0] // empty')"
  if [[ -z "$sku" ]]; then
    fail "$machine: $size is not offered in $LOCATION"
    continue
  fi
  blocked="$(jq -r '[.restrictions[]?.reasonCode] | join(",")' <<< "$sku")"
  if [[ -n "$blocked" ]]; then
    fail "$machine: $size is restricted for this subscription in $LOCATION ($blocked)"
    continue
  fi
  vcpus="$(jq -r '.capabilities[] | select(.name == "vCPUs") | .value' <<< "$sku")"
  mem="$(jq -r '.capabilities[] | select(.name == "MemoryGB") | .value' <<< "$sku")"
  gens="$(jq -r '.capabilities[] | select(.name == "HyperVGenerations") | .value' <<< "$sku")"
  pass "$machine: $size is available ($vcpus vCPU, $mem GB RAM, generations $gens)"
  [[ "$gens" == *V2* ]] || fail "$machine: $size does not support Gen2 VMs (the Ubuntu 24.04 image is Gen2)"
  # Only machines that do not exist yet need new quota
  if ! $exists; then
    family="$(jq -r '.family' <<< "$sku")"
    need[$family]=$(( ${need[$family]:-0} + vcpus ))
    need[cores]=$(( need[cores] + vcpus ))
  fi
done

step "Quotas in $LOCATION"
usage="$(az vm list-usage -l "$LOCATION" -o json)"
for quota in "${!need[@]}"; do
  used="$(jq -r --arg q "$quota" '.[] | select(.name.value == $q) | .currentValue' <<< "$usage")"
  limit="$(jq -r --arg q "$quota" '.[] | select(.name.value == $q) | .limit' <<< "$usage")"
  if [[ ! "$used" =~ ^[0-9]+$ || ! "$limit" =~ ^[0-9]+$ ]]; then
    fail "Could not read the '$quota' vCPU quota"
  elif (( limit - used >= need[$quota] )); then
    pass "vCPU quota '$quota': $used of $limit used, need ${need[$quota]} more"
  else
    fail "vCPU quota '$quota': $used of $limit used, need ${need[$quota]} more"
  fi
done

# Public IPs: AKS outbound + the app's LoadBalancer + the Jenkins VM = 3 in total
own_ips="$(az network public-ip list -o json |
  jq --arg rg "$(tr '[:upper:]' '[:lower:]' <<< "$RG")" '[.[] | select(.resourceGroup | ascii_downcase | contains($rg))] | length')"
need_ips=$(( own_ips >= 3 ? 0 : 3 - own_ips ))
net_usage="$(az network list-usages -l "$LOCATION" -o json)"
ip_rows="$(jq -c '.[] | select(.name.value | test("PublicIPAddresses$"; "i"))' <<< "$net_usage")"
if [[ -z "$ip_rows" ]]; then
  warn "Could not read the public IP quota"
fi
while read -r row; do
  [[ -n "$row" ]] || continue
  name="$(jq -r .name.localizedValue <<< "$row")"
  used="$(jq -r .currentValue <<< "$row")"
  limit="$(jq -r .limit <<< "$row")"
  if (( limit - used >= need_ips )); then
    pass "$name: $used of $limit used, need $need_ips more"
  else
    fail "$name: $used of $limit used, need $need_ips more"
  fi
done <<< "$ip_rows"

step "Services in $LOCATION"
if image="$(az vm image show -l "$LOCATION" --urn Canonical:ubuntu-24_04-lts:server:latest \
      --query "[name, hyperVGeneration]" -o tsv 2>/dev/null | paste -sd " ")"; then
  pass "Ubuntu 24.04 image available (version, generation: $image)"
else
  fail "Ubuntu 24.04 image (Canonical:ubuntu-24_04-lts:server) is not available in $LOCATION"
fi

if versions="$(az aks get-versions -l "$LOCATION" -o json 2>/dev/null)"; then
  default="$(jq -r '[.values[]? | select(.isDefault == true) | .version][0] // "unknown"' <<< "$versions")"
  pass "AKS is available (default Kubernetes $default)"
else
  fail "AKS is not available in $LOCATION"
fi

if quietly az acr show -n "$ACR_NAME"; then
  pass "Container registry $ACR_NAME already exists (yours)"
elif [[ "$(az acr check-name -n "$ACR_NAME" --query nameAvailable -o tsv)" == "true" ]]; then
  pass "Container registry name $ACR_NAME is free"
else
  fail "Container registry name $ACR_NAME is taken; change ACR_NAME in azure/common.sh"
fi

step "Cloud Shell tools"
for tool in jq kubectl curl ssh-keygen python3; do
  if command -v "$tool" >/dev/null; then pass "$tool found"; else fail "$tool is missing"; fi
done
if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
  pass "Python $(python3 -c 'import platform; print(platform.python_version())') (pinned Ansible needs 3.12+)"
else
  fail "Python 3.12+ is needed for the pinned ansible-core in ansible/requirements.txt"
fi

step "Result"
if (( FAILS > 0 )); then
  printf '  \e[31m%d check(s) failed\e[0m, %d warning(s). Nothing was created.\n' "$FAILS" "$WARNS"
  exit 1
fi
printf '  \e[32mAll checks passed\e[0m (%d warning(s)). Safe to run setup.\n' "$WARNS"
