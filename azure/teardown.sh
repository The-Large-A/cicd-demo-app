#!/usr/bin/env bash
# Delete EVERYTHING this project created in Azure (run after the viva). Cannot be undone.
source "$(dirname "$0")/common.sh"

step "This deletes resource group $RG (AKS, ACR, Jenkins VM, IPs, disks) and the budget"
read -rp "Type the resource group name to confirm: " answer
[[ "$answer" == "$RG" ]] || { echo "Cancelled."; exit 1; }

step "Delete the budget"
az rest --method delete -o none \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Consumption/budgets/$BUDGET_NAME?api-version=2023-05-01" ||
  info "no budget found"

step "Delete the resource group (takes ~10 min)"
az group delete -n "$RG" --yes
rm -rf "$OUT_DIR"
info "All project resources are deleted."
