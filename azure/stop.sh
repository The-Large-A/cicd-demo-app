#!/usr/bin/env bash
# End a work session: prune old images and stop everything that costs money while idle.
# Stopped resources keep their data; bash azure/start.sh brings them back.
source "$(dirname "$0")/common.sh"

step "Delete old images from ACR (keep the newest $KEEP_IMAGES)"
mapfile -t old_tags < <(az acr repository show-tags -n "$ACR_NAME" --repository "$APP_NAME" \
  --orderby time_desc -o tsv 2>/dev/null | tail -n +"$((KEEP_IMAGES + 1))")
for tag in "${old_tags[@]}"; do
  az acr repository delete -n "$ACR_NAME" --image "$APP_NAME:$tag" --yes -o none
  info "deleted $APP_NAME:$tag"
done
info "${#old_tags[@]} old image(s) removed"

step "Stop the AKS cluster"
if [[ "$(az aks show -g "$RG" -n "$AKS_NAME" --query powerState.code -o tsv)" == "Running" ]]; then
  az aks stop -g "$RG" -n "$AKS_NAME" -o none
fi
info "stopped"

step "Stop (deallocate) the Jenkins VM"
az vm deallocate -g "$RG" -n "$VM_NAME" -o none
info "stopped - compute billing has ended for both"
