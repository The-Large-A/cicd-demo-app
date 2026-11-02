#!/usr/bin/env bash
# Builds the kubeconfig Jenkins uses to deploy. It logs in as the jenkins-deployer
# service account (k8s/rbac.yaml), so it can only manage the app in the cicd-demo namespace.
# Usage: make-jenkins-kubeconfig.sh <admin-kubeconfig> <output-file>
set -euo pipefail

ADMIN="$1"
OUT="$2"
NS="cicd-demo"
TOKEN_SECRET="jenkins-deployer-token"
k() { kubectl --kubeconfig "$ADMIN" "$@"; }

# Kubernetes fills in the token a moment after the secret is created
TOKEN=""
for _ in $(seq 1 30); do
  TOKEN="$(k -n "$NS" get secret "$TOKEN_SECRET" -o jsonpath='{.data.token}' | base64 -d)"
  [[ -n "$TOKEN" ]] && break
  sleep 2
done
[[ -n "$TOKEN" ]] || { echo "Service account token was not created" >&2; exit 1; }

SERVER="$(k config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(k config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

umask 077
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: aks
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_DATA}
users:
  - name: jenkins-deployer
    user:
      token: ${TOKEN}
contexts:
  - name: jenkins-deployer
    context:
      cluster: aks
      user: jenkins-deployer
      namespace: ${NS}
current-context: jenkins-deployer
EOF

# Show that the permissions really are limited
can_i() { printf '  %-40s %s\n' "$*" "$(kubectl --kubeconfig "$OUT" auth can-i "$@" 2>/dev/null || true)"; }
echo "Jenkins kubeconfig written to $OUT. Permissions:"
can_i patch deployments -n "$NS"
can_i create services -n "$NS"
can_i get secrets -n "$NS"
can_i delete namespaces
can_i get pods -n kube-system
