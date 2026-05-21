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

## Cloner le projet complet

Les sous-modules ne sont pas récupérés par défaut — utiliser `--recurse-submodules` :

```bash
git clone --recurse-submodules https://github.com/COFRAP-EPSI-2026/cofrap-stack.git
```

Dépôt déjà cloné sans l'option ? Initialiser les sous-modules après coup :

```bash
git submodule update --init --recursive
```

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

## Lancer la stack complète en local

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

## Documentation

| Composant | Entrée | Documentation détaillée (bilingue FR/EN) |
|-----------|--------|------------------------------------------|
| Backend   | [`backend/README.md`](backend/README.md)   | [`backend/docs/`](backend/docs/)   |
| Frontend  | [`frontend/README.md`](frontend/README.md) | [`frontend/docs/`](frontend/docs/) |

## Structure du dépôt

```
.
├── backend/        # sous-module → cofrap-backend
├── frontend/       # sous-module → cofrap-frontend
├── .gitmodules     # déclaration des sous-modules
├── README.md
└── LICENSE
```

## Licence

[MIT](LICENSE) — projet académique MSPR TPRE912 (EPSI / Pro Alterna).
