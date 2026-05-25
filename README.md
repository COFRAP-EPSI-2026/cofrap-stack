# COFRAP Stack

Méta-dépôt du PoC **COFRAP** (MSPR TPRE912 — projet de développement serverless).
Il agrège, via des **sous-modules Git**, les deux dépôts qui composent le projet —
pour disposer d'un point d'entrée et d'un accès uniques sur l'ensemble.

## Composants

| Sous-module           | Dépôt                                                                       | Rôle                                                            |
|-----------------------|-----------------------------------------------------------------------------|-----------------------------------------------------------------|
| [`backend/`](backend)   | [`cofrap-backend`](https://github.com/COFRAP-EPSI-2026/cofrap-backend)   | 3 fonctions serverless OpenFaaS (Python / FastAPI) + MariaDB    |
| [`frontend/`](frontend) | [`cofrap-frontend`](https://github.com/COFRAP-EPSI-2026/cofrap-frontend) | SPA Vue 3 / Vite / TypeScript                                   |

> Chaque composant reste un dépôt **autonome** (sa propre CI, ses releases, son
> versionnement). Ce méta-dépôt ne fait que les **référencer** à un commit précis.

## Démarrage rapide

```bash
git clone https://github.com/COFRAP-EPSI-2026/cofrap-stack.git
cd cofrap-stack
```

Puis lancer le **script d'initialisation** — il récupère le code des sous-modules
(`backend/`, `frontend/`), crée `backend/.env` avec une clé de chiffrement, et
affiche les commandes de lancement :

```bash
bash scripts/init.sh        # Linux / macOS
```

```powershell
.\scripts\init.ps1          # Windows (PowerShell)
```

> Le script évite l'oubli classique des sous-modules : un simple `git clone`
> laisse `backend/` et `frontend/` **vides**. Équivalent manuel si besoin :
> `git submodule update --init --recursive`.

## Se mettre à jour sur le dernier code

Récupérer la dernière version de `main` de chaque composant :

```bash
git submodule update --remote --merge
git add backend frontend
git commit -m "chore: mise à jour des sous-modules"
```

Le commit fige les nouveaux pointeurs : le méta-dépôt sait toujours sur quel
commit exact de chaque composant il est aligné.

## Architecture

```
                Navigateur
                    │
                    ▼
   frontend ── SPA Vue 3 servie par nginx (statique)
                    │  appels /api/*  (proxy même origine, aucun CORS)
                    ▼
       Gateway OpenFaaS  (Traefik en local / gateway K8s en prod)
                    │
   backend ──┬── generate-password ─┐
             ├── generate-2fa ──────┼──►  MariaDB  (mots de passe + secrets TOTP chiffrés)
             └── authenticate-user ─┘
```

- **Frontend** : création de compte, authentification, renouvellement d'identifiants.
- **Backend** : génération de mot de passe (24 caractères), 2FA TOTP, chiffrement
  Fernet, rotation à 6 mois.

## Lancer la stack complète en local (sans cluster)

Pré-requis : Docker + Docker Compose, Node.js `>=22.12`, Yarn classic.

### 1. Backend — API + base de données

```bash
cd backend
cp .env.example .env
# générer une clé de chiffrement et l'ajouter au .env :
python -c "from cryptography.fernet import Fernet; print('ENCRYPTION_KEY=' + Fernet.generate_key().decode())" >> .env
docker compose up -d --build
```

→ Gateway des fonctions sur `http://localhost:8080`.

### 2. Frontend — interface

```bash
cd frontend
yarn install
yarn dev
```

→ `http://localhost:5173` — les appels `/api/*` sont proxifiés vers le backend.

Détails : [`backend/README.md`](backend/README.md) · [`frontend/README.md`](frontend/README.md).

## Déployer la stack sur Kubernetes (dev ou prod)

Pour déployer la stack **entière** (MariaDB + 3 fonctions backend + frontend nginx) sur un cluster K8s en une commande :

```bash
# Linux / macOS / WSL
./kubernetes/deploy.sh --env dev          # environnement dev
./kubernetes/deploy.sh --env prod         # environnement prod

# Windows
.\kubernetes\deploy.ps1 -Env dev
```

Le script gère MetalLB, OpenFaaS, les secrets, et les 2 charts Helm. Idempotent — peut être rejoué sans casser. Voir [`kubernetes/README.md`](kubernetes/README.md) pour la doc complète (variantes, override, troubleshooting).

> **GitOps avec ArgoCD + Image Updater** — la prochaine évolution naturelle : ArgoCD watche ce repo et reconcilie automatiquement à chaque push. Avec **ArgoCD Image Updater** câblé dans les manifestes fournis, **chaque release Release Please (backend ou frontend) déclenche automatiquement le redéploiement** de la stack concernée — sans intervention manuelle, sans toucher aux workflows CI/CD existants. Manifestes prêts à l'emploi dans [`kubernetes/argocd/`](kubernetes/argocd/README.md).

## Documentation

| Composant | Entrée | Documentation détaillée (bilingue FR/EN) |
|-----------|--------|------------------------------------------|
| Backend   | [`backend/README.md`](backend/README.md)   | [`backend/docs/`](backend/docs/)   |
| Frontend  | [`frontend/README.md`](frontend/README.md) | [`frontend/docs/`](frontend/docs/) |
| Stack K8s | [`kubernetes/README.md`](kubernetes/README.md) | [`kubernetes/argocd/README.md`](kubernetes/argocd/README.md) |

### Documentation opérationnelle (au niveau stack)

| Document                                          | À utiliser quand…                                                                            |
|---------------------------------------------------|-----------------------------------------------------------------------------------------------|
| [`docs/runbook-dev.md`](docs/runbook-dev.md)      | Tu déploies **la dev A → Z** — focus auto-MAJ sur chaque push branche `dev` (~1h)            |
| [`docs/runbook-prod.md`](docs/runbook-prod.md)    | Tu déploies **la prod A → Z** — focus releases stables `vX.Y.Z` (~1h-1h30)                  |
| [`docs/cheatsheet.md`](docs/cheatsheet.md)        | Tu veux **une commande** précise (kubectl, helm, argocd…) — aide-mémoire contextualisé COFRAP |
| [`kubernetes/README.md`](kubernetes/README.md)    | Tu déploies en Phase 1 avec `deploy.sh` ou tu comprends l'architecture                       |
| [`kubernetes/argocd/README.md`](kubernetes/argocd/README.md) | Tu prépares ou opères le mode GitOps (ArgoCD + Image Updater)                       |

## Structure du dépôt

```
.
├── backend/                       # sous-module → cofrap-backend (code live)
├── frontend/                      # sous-module → cofrap-frontend (code live)
├── kubernetes/                    # déploiement stack K8s (dev / prod)
│   ├── deploy.{sh,ps1}            # orchestrateur unique → backend + frontend
│   ├── uninstall.{sh,ps1}
│   ├── env/{dev,prod}.env         # variables (IP, hostname, tag, namespace)
│   ├── loadbalancing/             # MetalLB + IPAddressPool dev / prod
│   ├── values/                    # overrides Helm — consommés par bash ET ArgoCD
│   └── argocd/                    # Phase 2 — App-of-Apps GitOps
├── docs/                          # documentation transverse au projet
├── diagrams/                      # diagrammes d'architecture
├── screenshots/                   # captures d'écran (rapport, soutenance)
├── scripts/                       # scripts utilitaires (init des submodules)
├── .github/                       # workflows / templates GitHub du méta-dépôt
├── .gitmodules                    # déclaration des sous-modules
├── README.md
└── LICENSE
```

## Licence

[MIT](LICENSE) — projet académique MSPR TPRE912 (EPSI / Pro Alterna).
