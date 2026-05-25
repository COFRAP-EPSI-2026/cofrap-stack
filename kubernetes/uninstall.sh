#!/usr/bin/env bash
#
# uninstall.sh - supprime la stack COFRAP (dev ou prod) du cluster K8s.
#
# Par défaut :
#   - Désinstalle les 2 releases Helm (backend + frontend)
#   - Supprime les Secrets `mariadb-password` et `encryption-key` dans openfaas-fn
#   - Supprime les PVC MariaDB (sinon les données restent)
#   - Supprime le namespace stack
#   - Garde MetalLB et OpenFaaS (infra)
#
# Avec --purge-openfaas : supprime aussi OpenFaaS Community.
# Avec --purge-metallb  : supprime aussi MetalLB (les autres workloads du cluster
#                        qui utilisent des Services type LoadBalancer perdront leur IP).
#
# Usage :
#   ./kubernetes/uninstall.sh --env dev
#   ./kubernetes/uninstall.sh --env prod --purge-openfaas

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_DIR="${ROOT}/kubernetes"

info()  { printf '\n==> \033[1;36m%s\033[0m\n' "$1"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$1"; }
warn()  { printf '   \033[1;33m!\033[0m %s\n' "$1"; }
err()   { printf '\n\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 --env {dev|prod} [--purge-openfaas] [--purge-metallb] [--keep-secrets]

Options :
  --env <dev|prod>   Environnement cible (REQUIS).
  --purge-openfaas   Désinstalle aussi OpenFaaS Community.
  --purge-metallb    Désinstalle aussi MetalLB (impacte tous les LoadBalancer).
  --keep-secrets     Conserve le cache .secrets.<env> (par défaut : supprimé).
  -h, --help         Affiche cette aide.
EOF
  exit 0
}

ENV=""
PURGE_OPENFAAS=0
PURGE_METALLB=0
KEEP_SECRETS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)             ENV="${2:-}"; shift 2 ;;
    --purge-openfaas)  PURGE_OPENFAAS=1; shift ;;
    --purge-metallb)   PURGE_METALLB=1; shift ;;
    --keep-secrets)    KEEP_SECRETS=1; shift ;;
    -h|--help)         usage ;;
    *) err "Argument inconnu: $1" ;;
  esac
done

[[ "$ENV" == "dev" || "$ENV" == "prod" ]] || err "--env doit être dev ou prod"

ENV_FILE="${KUBE_DIR}/env/${ENV}.env"
[[ -f "$ENV_FILE" ]] || err "Fichier d'env introuvable: $ENV_FILE"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

info "Désinstallation COFRAP — env: ${ENV} / namespace: ${NAMESPACE}"

# --- 1. Helm releases ----------------------------------------------------
info "Désinstallation des releases Helm"
helm uninstall "$RELEASE_FRONTEND" -n "$NAMESPACE" 2>/dev/null && \
  ok "Frontend ($RELEASE_FRONTEND) supprimé" || warn "Frontend non trouvé"
helm uninstall "$RELEASE_BACKEND"  -n "$NAMESPACE" 2>/dev/null && \
  ok "Backend  ($RELEASE_BACKEND) supprimé"  || warn "Backend non trouvé"

# --- 2. Secrets dans openfaas-fn (créés par le chart cofrap) -------------
info "Nettoyage des secrets dans ${OPENFAAS_FN_NAMESPACE}"
kubectl -n "$OPENFAAS_FN_NAMESPACE" delete secret mariadb-password encryption-key \
  --ignore-not-found
ok "Secrets MariaDB + Fernet supprimés"

# --- 3. PVC MariaDB ------------------------------------------------------
info "Suppression des PVC MariaDB dans ${NAMESPACE}"
kubectl -n "$NAMESPACE" delete pvc -l 'app.kubernetes.io/name=mariadb' --ignore-not-found
ok "PVC MariaDB supprimés (données perdues)"

# --- 4. Namespace --------------------------------------------------------
info "Suppression du namespace ${NAMESPACE}"
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false
ok "Namespace en cours de suppression"

# --- 5. OpenFaaS (opt-in) ------------------------------------------------
if [[ "$PURGE_OPENFAAS" == "1" ]]; then
  info "Désinstallation d'OpenFaaS Community"
  helm uninstall openfaas -n "$OPENFAAS_NAMESPACE" 2>/dev/null || warn "OpenFaaS non trouvé"
  kubectl delete namespace "$OPENFAAS_NAMESPACE" "$OPENFAAS_FN_NAMESPACE" \
    --ignore-not-found --wait=false
  ok "OpenFaaS supprimé"
fi

# --- 6. MetalLB (opt-in) -------------------------------------------------
if [[ "$PURGE_METALLB" == "1" ]]; then
  info "Désinstallation de MetalLB"
  kubectl delete -f "${KUBE_DIR}/loadbalancing/metallb-pool.${ENV}.yaml" --ignore-not-found
  kubectl delete -f "${KUBE_DIR}/loadbalancing/metallb-native.yaml"      --ignore-not-found
  ok "MetalLB supprimé"
fi

# --- 7. Cache secrets ----------------------------------------------------
SECRETS_FILE="${KUBE_DIR}/.secrets.${ENV}"
if [[ -f "$SECRETS_FILE" && "$KEEP_SECRETS" == "0" ]]; then
  rm -f "$SECRETS_FILE"
  ok "Cache .secrets.${ENV} supprimé"
elif [[ -f "$SECRETS_FILE" ]]; then
  warn "Cache .secrets.${ENV} conservé (--keep-secrets)"
fi

info "Désinstallation terminée ✓"
