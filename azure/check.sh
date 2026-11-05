#!/usr/bin/env bash
# Read-only health check of everything this project keeps in Azure and Kubernetes.
# Changes nothing. Works whether the VM and cluster are running or stopped:
#   bash azure/check.sh
source "$(dirname "$0")/common.sh"

step "Azure resources in $RG"
if ! quietly az group show -n "$RG"; then
  fail "Resource group $RG does not exist - run azure/setup.sh"
  exit 1
fi
az resource list -g "$RG" --query "sort_by(@, &type)[].{Resource: type, Name: name}" -o table

if acr="$(az acr show -n "$ACR_NAME" -o json 2>/dev/null)"; then
  pass "Container registry $(jq -r .loginServer <<< "$acr") ($(jq -r .sku.name <<< "$acr"))"
  tags="$(az acr repository show-tags -n "$ACR_NAME" --repository "$APP_NAME" --orderby time_desc -o tsv 2>/dev/null | tr '\n' ' ' || true)"
  if [[ -n "$tags" ]]; then pass "Images of $APP_NAME: $tags"; else warn "No $APP_NAME images yet (the pipeline pushes them)"; fi
else
  fail "Container registry $ACR_NAME is missing"
fi

AKS_STATE=""
if aks="$(az aks show -g "$RG" -n "$AKS_NAME" -o json 2>/dev/null)"; then
  AKS_STATE="$(jq -r .powerState.code <<< "$aks")"
  pool="$(jq -r '.agentPoolProfiles[0] | "\(.count) x \(.vmSize), Kubernetes \(.currentOrchestratorVersion // .orchestratorVersion)"' <<< "$aks")"
  if [[ "$(jq -r .provisioningState <<< "$aks")" == "Succeeded" ]]; then
    pass "AKS cluster $AKS_NAME: $pool, $AKS_STATE"
  else
    fail "AKS cluster $AKS_NAME is in state $(jq -r .provisioningState <<< "$aks")"
  fi
else
  fail "AKS cluster $AKS_NAME is missing"
fi

VM_STATE=""
if vm="$(az vm get-instance-view -g "$RG" -n "$VM_NAME" -o json 2>/dev/null)"; then
  VM_STATE="$(jq -r '[.instanceView.statuses[] | select(.code | startswith("PowerState/")) | .displayStatus][0]' <<< "$vm")"
  pass "Jenkins VM $VM_NAME: $(jq -r .hardwareProfile.vmSize <<< "$vm"), $VM_STATE"
  principal="$(jq -r '.identity.principalId // empty' <<< "$vm")"
  aks_id=""
  [[ -n "${aks:-}" ]] && aks_id="$(jq -r .id <<< "$aks")"
  if [[ -n "$principal" && -n "$aks_id" ]] &&
     [[ -n "$(az role assignment list --assignee "$principal" --scope "$aks_id" --query "[].roleDefinitionName" -o tsv 2>/dev/null)" ]]; then
    pass "VM identity may stop the AKS cluster (nightly cost guard)"
  else
    warn "VM identity has no role on the AKS cluster; the nightly AKS stop will not work"
  fi
else
  fail "Jenkins VM $VM_NAME is missing"
fi

if ip="$(az network public-ip show -g "$RG" -n pip-jenkins -o json 2>/dev/null)"; then
  if [[ "$(jq -r .publicIPAllocationMethod <<< "$ip")" == "Static" ]]; then
    pass "Jenkins IP $(jq -r .ipAddress <<< "$ip") is static (survives stop/start)"
  else
    warn "Jenkins IP is not static; it can change after a stop"
  fi
else
  fail "Public IP pip-jenkins is missing"
fi

for rule in allow-ssh-cloudshell allow-jenkins; do
  if r="$(az network nsg rule show -g "$RG" --nsg-name "$NSG_NAME" -n "$rule" -o json 2>/dev/null)"; then
    pass "Firewall rule $rule: port $(jq -r .destinationPortRange <<< "$r") from $(jq -r '(.sourceAddressPrefixes | length) as $n | if $n > 0 then "\($n) address ranges" else .sourceAddressPrefix end' <<< "$r")"
  else
    fail "Firewall rule $rule is missing"
  fi
done

schedule="$(az resource show -g "$RG" -n "shutdown-computevm-$VM_NAME" --resource-type Microsoft.DevTestLab/schedules -o json 2>/dev/null || true)"
if [[ -n "$schedule" && "$(jq -r .properties.status <<< "$schedule")" == "Enabled" ]]; then
  pass "VM auto-shutdown enabled at $(jq -r .properties.dailyRecurrence.time <<< "$schedule") $(jq -r .properties.timeZoneId <<< "$schedule")"
else
  fail "VM auto-shutdown is not enabled"
fi

locks="$(az lock list -g "$RG" --query "[].name" -o tsv 2>/dev/null | tr '
' ' ' || true)"
if [[ -n "${locks// /}" ]]; then
  pass "Delete lock on $RG: $locks(resources cannot be deleted by accident)"
else
  info "No delete lock on $RG (optional, see README)"
fi

if budget="$(az rest --method get -o json \
      --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Consumption/budgets/$BUDGET_NAME?api-version=2023-05-01" 2>/dev/null)"; then
  unit="$(jq -r '.properties.currentSpend.unit // ""' <<< "$budget")"
  spent="$(jq -r '(.properties.currentSpend.amount // 0) * 100 | round / 100' <<< "$budget")"
  pass "Budget $BUDGET_NAME: $(jq -r .properties.amount <<< "$budget") $unit per month, spent so far $spent $unit"
else
  warn "Budget $BUDGET_NAME not found"
fi

step "Kubernetes"
if [[ "$AKS_STATE" != "Running" ]]; then
  warn "AKS is ${AKS_STATE:-missing}: its state is saved; run azure/start.sh to check the workloads"
else
  admin_kubectl get nodes >/dev/null   # fetch the admin kubeconfig once
  k() { kubectl --kubeconfig "$ADMIN_KUBECONFIG" "$@"; }
  ready="$(k get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{" "}{end}')"
  if [[ "$ready" == *True* && "$ready" != *False* ]]; then pass "Node(s) Ready"; else fail "Node not Ready: $ready"; fi

  psa="$(k get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)"
  if [[ -n "$psa" ]]; then pass "Namespace $NAMESPACE (pod security: $psa)"; else fail "Namespace $NAMESPACE is missing"; fi

  for object in resourcequota/cicd-demo-quota limitrange/cicd-demo-defaults serviceaccount/jenkins-deployer \
                role/app-deployer rolebinding/jenkins-deployer secret/jenkins-deployer-token; do
    if quietly k -n "$NAMESPACE" get "$object"; then pass "$object"; else fail "$object is missing"; fi
  done

  if quietly k -n "$NAMESPACE" get deployment "$APP_NAME"; then
    replicas="$(k -n "$NAMESPACE" get deployment "$APP_NAME" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
    image="$(k -n "$NAMESPACE" get deployment "$APP_NAME" -o jsonpath='{.spec.template.spec.containers[0].image}')"
    if [[ "${replicas%/*}" == "${replicas#*/}" ]]; then pass "Deployment $replicas ready, image $image"; else fail "Deployment only $replicas ready"; fi
    app_ip="$(k -n "$NAMESPACE" get service "$APP_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "$app_ip" ]] && status="$(curl -fsS -m 10 "http://$app_ip/api/status" 2>/dev/null)"; then
      pass "App at http://$app_ip answers: version $(jq -r .version <<< "$status"), build #$(jq -r .buildNumber <<< "$status"), commit $(jq -r .gitCommit <<< "$status")"
    else
      fail "App is not answering at http://${app_ip:-<no public IP>}"
    fi
  else
    warn "App not deployed yet (the first main build deploys it)"
  fi
fi

step "Jenkins server"
if [[ "$VM_STATE" != "VM running" ]]; then
  warn "Jenkins VM is ${VM_STATE#VM }: Jenkins' data is kept on its disk; run azure/start.sh to check it"
else
  info "Asking the VM directly (takes about 30 seconds)..."
  # Prints only service states, job names and credential IDs - never secret values.
  # shellcheck disable=SC2016  # single quotes on purpose: this script runs on the VM
  report="$(az vm run-command invoke -g "$RG" -n "$VM_NAME" --command-id RunShellScript --query "value[0].message" -o tsv --scripts '
    for s in jenkins docker stop-aks.timer; do echo "SERVICE $s $(systemctl is-active $s)"; done
    echo "HTTP $(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login)"
    echo "JOBS $(ls /var/lib/jenkins/jobs 2>/dev/null | tr "\n" " ")"
    echo "CREDS $(grep -o "<id>[^<]*</id>" /var/lib/jenkins/credentials.xml 2>/dev/null | sed "s/<[^>]*>//g" | tr "\n" " ")"
    echo "DISK $(df -h / | awk "NR==2 {print \$5}")"
  ' 2>/dev/null || true)"
  if [[ -z "$report" ]]; then
    fail "Could not run the check on the VM"
  else
    while read -r _ name state; do
      if [[ "$state" == "active" ]]; then pass "$name is running"; else fail "$name is $state"; fi
    done < <(grep '^SERVICE ' <<< "$report")
    if grep -q '^HTTP 200' <<< "$report"; then pass "Jenkins answers on port 8080"; else fail "Jenkins does not answer on port 8080"; fi
    jobs="$(grep '^JOBS ' <<< "$report" | cut -d' ' -f2-)"
    if [[ "$jobs" == *cicd-demo-app* ]]; then pass "Pipeline job saved: $jobs"; else warn "Pipeline job cicd-demo-app not created yet"; fi
    creds="$(grep '^CREDS ' <<< "$report" | cut -d' ' -f2-)"
    missing=""
    for id in acr-credentials aks-kubeconfig github-token; do [[ " $creds " == *" $id "* ]] || missing+="$id "; done
    if [[ -z "$missing" ]]; then pass "Credentials saved: $creds"; else warn "Credentials missing: $missing"; fi
    pass "VM disk used: $(grep '^DISK ' <<< "$report" | cut -d' ' -f2)"
  fi
fi

step "Result"
if (( FAILS > 0 )); then
  printf '  \e[31m%d problem(s)\e[0m and %d warning(s) found.\n' "$FAILS" "$WARNS"
  exit 1
fi
printf '  \e[32mEverything is in place\e[0m (%d warning(s)).\n' "$WARNS"
