#!/usr/bin/env bash
#
# init.sh - prepare le meta-depot cofrap-stack pour le developpement local.
#
#   1. recupere le code des sous-modules backend/ et frontend/
#   2. cree backend/.env avec une cle de chiffrement generee
#   3. affiche les commandes pour lancer la stack
#
# Idempotent : peut etre relance sans risque.
# Pour passer les sous-modules sur le dernier main : git submodule update --remote
#
set -euo pipefail

# Racine du depot = dossier parent de scripts/
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

info() { printf '\n==> %s\n' "$1"; }
ok()   { printf 'OK   : %s\n' "$1"; }
warn() { printf 'WARN : %s\n' "$1"; }

# --- 1. Pre-requis ----------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  printf 'ERREUR : git est introuvable. Installe Git puis relance.\n' >&2
  exit 1
fi
command -v docker >/dev/null 2>&1 || warn "docker introuvable - requis pour lancer le backend."
command -v node   >/dev/null 2>&1 || warn "node introuvable - requis pour lancer le frontend."

# --- 2. Sous-modules (backend + frontend) -----------------------------------
info "Recuperation des sous-modules backend/ et frontend/..."
git submodule sync --recursive
git submodule update --init --recursive
ok "Sous-modules a jour."

# --- 3. Fichier .env du backend ---------------------------------------------
info "Configuration de backend/.env..."
if [ -f backend/.env ]; then
  ok "backend/.env existe deja - conserve."
elif [ -f backend/.env.example ]; then
  cp backend/.env.example backend/.env
  # Cle Fernet = base64 url-safe de 32 octets aleatoires
  key="$(head -c 32 /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_')"
  tmp="$(mktemp)"
  sed "s|^ENCRYPTION_KEY=.*|ENCRYPTION_KEY=${key}|" backend/.env > "$tmp"
  mv "$tmp" backend/.env
  ok "backend/.env cree avec une ENCRYPTION_KEY generee."
else
  warn "backend/.env.example introuvable - les sous-modules sont-ils initialises ?"
fi

# --- 4. Prochaines etapes ---------------------------------------------------
cat <<'EOF'

------------------------------------------------------------
 Meta-depot pret. Pour lancer la stack complete :

   Backend    cd backend  && docker compose up -d --build
   Frontend   cd frontend && yarn install && yarn dev

 Puis ouvrir : http://localhost:5173
------------------------------------------------------------
EOF
