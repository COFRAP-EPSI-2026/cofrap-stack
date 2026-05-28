#!/usr/bin/env bash
#
# create-secrets.sh - pré-crée les 3 Secrets de la stack COFRAP dans le cluster.
#
# Nécessaire en mode GitOps (ArgoCD) où le chart tourne avec secrets.create=false :
# le chart ne crée plus les secrets, ils doivent exister AVANT le sync ArgoCD.
#
# Source les valeurs depuis kubernetes/.secrets.<env> (généré par deploy.sh).
# Idempotent (kubectl apply).
#
# Usage :
#   ./kubernetes/create-secrets.sh --env dev
#   ./kubernetes/create-secrets.sh --env prod

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_DIR="${ROOT}/kubernetes"

err() { printf '\n\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }
ok()  { printf '   \033[1;32m✓\033[0m %s\n' "$1"; }

ENV=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="${2:-}"; shift 2 ;;
    *) err "Argument inconnu: $1 (usage: --env dev|prod)" ;;
  esac
done
[[ "$ENV" == "dev" || "$ENV" == "prod" ]] || err "--env doit être dev ou prod"

# Charge les variables d'env (namespaces, release)
ENV_FILE="${KUBE_DIR}/env/${ENV}.env"
[[ -f "$ENV_FILE" ]] || err "Fichier d'env introuvable: $ENV_FILE"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# Charge les valeurs de secrets (générées par deploy.sh)
SECRETS_FILE="${KUBE_DIR}/.secrets.${ENV}"
[[ -f "$SECRETS_FILE" ]] || err "Cache de secrets introuvable: ${SECRETS_FILE}
  → lance d'abord ./kubernetes/deploy.sh --env ${ENV} (Phase 1) pour les générer,
    ou restaure-le depuis ton vault."
# shellcheck disable=SC1090
source "$SECRETS_FILE"

printf '\n==> Pré-création des secrets COFRAP (env=%s)\n' "$ENV"

# Namespaces
kubectl create namespace "$OPENFAAS_FN_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$NAMESPACE"             --dry-run=client -o yaml | kubectl apply -f -

# 1. encryption-key (openfaas-fn) — lu par crypto.py des fonctions
kubectl -n "$OPENFAAS_FN_NAMESPACE" create secret generic encryption-key \
  --from-literal=encryption-key="$ENCRYPTION_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "encryption-key (${OPENFAAS_FN_NAMESPACE})"

# 2. mariadb-password (openfaas-fn) — lu par db.py des fonctions
kubectl -n "$OPENFAAS_FN_NAMESPACE" create secret generic mariadb-password \
  --from-literal=mariadb-password="$MARIADB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "mariadb-password (${OPENFAAS_FN_NAMESPACE})"

# 3. <release>-mariadb-credentials (namespace stack) — envFrom du StatefulSet MariaDB
#    Le nom suit cofrap.fullname = RELEASE_BACKEND (car "cofrap" ⊂ release name).
kubectl -n "$NAMESPACE" create secret generic "${RELEASE_BACKEND}-mariadb-credentials" \
  --from-literal=MARIADB_ROOT_PASSWORD="$MARIADB_ROOT_PASSWORD" \
  --from-literal=MARIADB_DATABASE="${DB_NAME:-cofrap}" \
  --from-literal=MARIADB_USER="${DB_USER:-cofrap}" \
  --from-literal=MARIADB_PASSWORD="$MARIADB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "${RELEASE_BACKEND}-mariadb-credentials (${NAMESPACE})"

printf '\n   Secrets prêts. ArgoCD peut maintenant synchroniser (secrets.create=false).\n\n'
