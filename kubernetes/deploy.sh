#!/usr/bin/env bash
#
# deploy.sh - déploie la stack COFRAP complète (dev ou prod) sur un cluster K8s.
#
# Enchaînement :
#   1. Vérifie kubectl + helm + accès cluster
#   2. (--install-metallb)  Applique MetalLB + pool d'IPs de l'env
#   3. (--install-openfaas) Installe OpenFaaS Community via Helm
#   4. Génère/récupère les secrets (Fernet key + 2 mots de passe MariaDB)
#   5. Déploie le chart backend  (cofrap)            avec values/backend.<env>.yaml
#   6. Déploie le chart frontend (cofrap-frontend)   avec values/frontend.<env>.yaml
#   7. Affiche le récap (IP VIP, hostname, credentials OpenFaaS)
#
# Idempotent : peut être relancé sans risque, les secrets sont mis en cache
# dans `.secrets.<env>` (gitignoré) pour ne pas régénérer à chaque run.
#
# Usage :
#   ./kubernetes/deploy.sh --env dev
#   ./kubernetes/deploy.sh --env prod
#   ./kubernetes/deploy.sh --env dev --install-metallb --install-openfaas
#
# Variables override (sans toucher au fichier env) :
#   IMAGE_TAG_BACKEND=v2026.3.2 ./kubernetes/deploy.sh --env prod

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_DIR="${ROOT}/kubernetes"

# --- Helpers --------------------------------------------------------------
info()  { printf '\n==> \033[1;36m%s\033[0m\n' "$1"; }
ok()    { printf '   \033[1;32m✓\033[0m %s\n' "$1"; }
warn()  { printf '   \033[1;33m!\033[0m %s\n' "$1"; }
err()   { printf '\n\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 --env {dev|prod} [--install-metallb] [--install-openfaas]

Options :
  --env <dev|prod>      Environnement cible (REQUIS).
  --install-metallb     Installe MetalLB natif + applique le pool d'IPs.
                        Par défaut : skippé (assumé déjà installé).
  --install-openfaas    Installe OpenFaaS Community via Helm.
                        Par défaut : skippé (assumé déjà installé).
  -h, --help            Affiche cette aide.

Variables override (env vars) :
  IMAGE_TAG_BACKEND, IMAGE_TAG_FRONTEND, NAMESPACE, INGRESS_HOST, ...
EOF
  exit 0
}

# --- Args -----------------------------------------------------------------
ENV=""
INSTALL_METALLB=0
INSTALL_OPENFAAS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)              ENV="${2:-}"; shift 2 ;;
    --install-metallb)  INSTALL_METALLB=1; shift ;;
    --install-openfaas) INSTALL_OPENFAAS=1; shift ;;
    -h|--help)          usage ;;
    *) err "Argument inconnu: $1 (--help pour l'aide)" ;;
  esac
done

[[ "$ENV" == "dev" || "$ENV" == "prod" ]] || err "--env doit être dev ou prod"

# --- Charge les variables d'environnement --------------------------------
ENV_FILE="${KUBE_DIR}/env/${ENV}.env"
[[ -f "$ENV_FILE" ]] || err "Fichier d'env introuvable: $ENV_FILE"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

info "Déploiement COFRAP — environnement: ${ENV}"
echo "   Namespace       : $NAMESPACE"
echo "   Release backend : $RELEASE_BACKEND"
echo "   Release front   : $RELEASE_FRONTEND"
echo "   Ingress host    : $INGRESS_HOST"
echo "   MetalLB IP      : $METALLB_IP"
echo "   Tag backend     : $IMAGE_TAG_BACKEND"
echo "   Tag frontend    : $IMAGE_TAG_FRONTEND"

# --- 1. Pré-requis --------------------------------------------------------
info "Vérification des pré-requis"
command -v kubectl >/dev/null 2>&1 || err "kubectl est introuvable"
command -v helm    >/dev/null 2>&1 || err "helm est introuvable"
kubectl cluster-info >/dev/null 2>&1 || err "kubectl ne peut pas joindre le cluster"
ok "kubectl + helm + cluster OK"

# --- 2. MetalLB (optionnel) ----------------------------------------------
if [[ "$INSTALL_METALLB" == "1" ]]; then
  info "Installation de MetalLB (manifeste natif)"
  kubectl apply -f "${KUBE_DIR}/loadbalancing/metallb-native.yaml"
  kubectl -n metallb-system wait --for=condition=Ready pod --all --timeout=120s || true
  kubectl apply -f "${KUBE_DIR}/loadbalancing/metallb-pool.${ENV}.yaml"
  ok "MetalLB installé + pool ${ENV} appliqué (${METALLB_IP})"
else
  warn "MetalLB skippé (assumé déjà installé). --install-metallb pour forcer."
fi

# --- 3. OpenFaaS (optionnel) ---------------------------------------------
if [[ "$INSTALL_OPENFAAS" == "1" ]]; then
  info "Installation d'OpenFaaS Community"
  helm repo add openfaas https://openfaas.github.io/faas-netes/ >/dev/null
  helm repo update >/dev/null
  kubectl create namespace "$OPENFAAS_NAMESPACE"    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace "$OPENFAAS_FN_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install openfaas openfaas/openfaas \
    --namespace "$OPENFAAS_NAMESPACE" \
    --set functionNamespace="$OPENFAAS_FN_NAMESPACE" \
    --set generateBasicAuth=true \
    --wait --timeout 5m
  ok "OpenFaaS installé dans ${OPENFAAS_NAMESPACE}"
else
  warn "OpenFaaS skippé (assumé déjà installé). --install-openfaas pour forcer."
fi

# --- 4. Secrets (idempotent — cache dans .secrets.<env>) -----------------
SECRETS_FILE="${KUBE_DIR}/.secrets.${ENV}"
if [[ -f "$SECRETS_FILE" ]]; then
  info "Réutilisation des secrets existants (${SECRETS_FILE})"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  ok "Secrets chargés depuis le cache"
else
  info "Génération de nouveaux secrets"
  if command -v python >/dev/null 2>&1; then
    ENCRYPTION_KEY="$(python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
  elif command -v openssl >/dev/null 2>&1; then
    # Fallback : 32 octets URL-safe base64 (compatible Fernet)
    ENCRYPTION_KEY="$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '\n=')="
  else
    err "Ni python ni openssl trouvés pour générer la clé Fernet"
  fi
  MARIADB_PASSWORD="$(openssl rand -hex 16)"
  MARIADB_ROOT_PASSWORD="$(openssl rand -hex 16)"
  cat > "$SECRETS_FILE" <<EOF
# Secrets générés le $(date -u +%FT%TZ) pour env=${ENV}.
# NE PAS COMMITER. Supprimer pour régénérer (perte des données chiffrées).
ENCRYPTION_KEY='${ENCRYPTION_KEY}'
MARIADB_PASSWORD='${MARIADB_PASSWORD}'
MARIADB_ROOT_PASSWORD='${MARIADB_ROOT_PASSWORD}'
EOF
  chmod 600 "$SECRETS_FILE"
  ok "Secrets générés et mis en cache (${SECRETS_FILE} — chmod 600)"
fi

# --- 5. Backend (chart cofrap) -------------------------------------------
info "Déploiement du backend (chart cofrap → release ${RELEASE_BACKEND})"
helm upgrade --install "$RELEASE_BACKEND" "${ROOT}/backend/deploy/helm/cofrap" \
  --namespace "$NAMESPACE" --create-namespace \
  --values "${KUBE_DIR}/values/backend.${ENV}.yaml" \
  --set secrets.encryptionKey="$ENCRYPTION_KEY" \
  --set secrets.mariadbPassword="$MARIADB_PASSWORD" \
  --set secrets.mariadbRootPassword="$MARIADB_ROOT_PASSWORD" \
  --set functions.version="$IMAGE_TAG_BACKEND" \
  --wait --timeout 10m
ok "Backend déployé"

# --- 6. Frontend (chart cofrap-frontend) ---------------------------------
info "Déploiement du frontend (chart cofrap-frontend → release ${RELEASE_FRONTEND})"
helm upgrade --install "$RELEASE_FRONTEND" "${ROOT}/frontend/deploy/helm/cofrap-frontend" \
  --namespace "$NAMESPACE" --create-namespace \
  --values "${KUBE_DIR}/values/frontend.${ENV}.yaml" \
  --set image.tag="$IMAGE_TAG_FRONTEND" \
  --set ingress.host="$INGRESS_HOST" \
  --wait --timeout 5m
ok "Frontend déployé"

# --- 7. Récap -------------------------------------------------------------
info "Stack COFRAP déployée ✓"
cat <<EOF

  Environnement     : ${ENV}
  Namespace         : ${NAMESPACE}
  Hostname public   : https://${INGRESS_HOST}
  IP MetalLB (VIP)  : ${METALLB_IP}

  Vérifier les pods :
    kubectl -n ${NAMESPACE} get pods
    kubectl -n ${OPENFAAS_FN_NAMESPACE} get pods -l 'faas_function'

  Mot de passe admin OpenFaaS :
    kubectl -n ${OPENFAAS_NAMESPACE} get secret basic-auth \\
      -o jsonpath='{.data.basic-auth-password}' | base64 -d ; echo

  Re-déployer sans regénérer les secrets : relancer ce script.
  Supprimer la stack : ./kubernetes/uninstall.sh --env ${ENV}

EOF
