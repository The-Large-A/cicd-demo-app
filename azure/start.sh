#!/usr/bin/env bash
# Start the Jenkins VM and the AKS cluster for a work session. Run in Azure Cloud Shell:
#   bash azure/start.sh [your-laptop-public-ip]   (pass the IP if it changed, to update the firewall)
source "$(dirname "$0")/common.sh"

step "Start the Jenkins VM"
az vm start -g "$RG" -n "$VM_NAME" -o none
info "running"

step "Start the AKS cluster (takes a few minutes)"
if [[ "$(az aks show -g "$RG" -n "$AKS_NAME" --query powerState.code -o tsv)" == "Stopped" ]]; then
  az aks start -g "$RG" -n "$AKS_NAME" -o none
fi
info "running"

if [[ -n "${1:-}" ]]; then
  require_ip "$1"
  step "Update the firewall for your new IP"
  update_firewall "$1"
fi

step "Endpoints"
VM_IP="$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)"
APP_IP="$(admin_kubectl -n "$NAMESPACE" get service "$APP_NAME" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
info "Jenkins: http://$VM_IP:8080"
if [[ -n "$APP_IP" ]]; then info "App:     http://$APP_IP"; else info "App:     not deployed yet"; fi
info "Remember: bash azure/stop.sh when you are done."
