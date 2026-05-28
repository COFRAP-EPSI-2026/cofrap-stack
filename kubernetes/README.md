# `kubernetes/` — déploiement stack COFRAP

Déploiement de la stack COFRAP **complète** (MariaDB + 3 fonctions backend + frontend nginx) sur Kubernetes, en **un seul script**, pour les environnements **dev** et **prod**.

> 🇬🇧 English version at the end of this file.

## Sommaire

- [Architecture par environnement](#architecture-par-environnement)
- [Pré-requis](#pré-requis)
- [Déploiement Phase 1 — scripté](#déploiement-phase-1--scripté)
- [Cycle de vie : install / upgrade / uninstall](#cycle-de-vie--install--upgrade--uninstall)
- [Structure](#structure)
- [Environnements dev / prod](#environnements-dev--prod)
- [Secrets](#secrets)
- [Phase 2 — GitOps avec ArgoCD](#phase-2--gitops-avec-argocd)
- [Troubleshooting](#troubleshooting)
- [English version](#english-version)

## Architecture par environnement

Les deux environnements partagent **le même code, les mêmes charts Helm et les mêmes
images GHCR**. Ils diffèrent par **le mode de déploiement** :

- **DEV → GitOps complet (ArgoCD + Image Updater)** : auto-MAJ à chaque push sur la
  branche `dev`. C'est l'environnement d'itération — on pousse, ça se déploie tout seul.
- **PROD → déploiement scripté (`deploy.sh`)** : maîtrisé, manuel, validé par l'humain.
  ArgoCD **n'est pas activé** mais reste **activable à tout moment** (les manifestes
  ArgoCD prod existent déjà dans [`argocd/`](argocd/) — il suffit de les appliquer).

### DEV — GitOps (ArgoCD actif)

```
  Développeur
     │  git push origin dev   (backend ou frontend)
     ▼
  GitHub ──► pre-release.yml ──► build + push image :dev sur GHCR
                                          │
            ┌─────────────────────────────┘  (polling 2 min)
            ▼
  ArgoCD Image Updater  ──► commit auto du nouveau digest dans
  (sur cluster dev)          cofrap-stack/kubernetes/values/<comp>.dev.yaml
                                          │
            ┌─────────────────────────────┘  (polling Git ~3 min)
            ▼
  ArgoCD (App-of-Apps cofrap-stack-dev)
     ├─ Application cofrap-backend-dev   ─┐
     └─ Application cofrap-frontend-dev  ─┤ helm template + apply (selfHeal: true)
                                          ▼
  Cluster K3s dev  (ns cofrap-dev + openfaas-fn)
     ├─ MariaDB + 3 fonctions OpenFaaS + frontend nginx
     └─ VIP MetalLB 192.168.1.240 ──► Cloudflare Tunnel ──► cofrap-dev.home-maurras.fr

  Secrets : pré-créés hors Git (secrets.create=false) — kubernetes/create-secrets.sh
```

→ Mise en place pas-à-pas : [`../docs/runbook-dev.md`](../docs/runbook-dev.md).

### PROD — scripté (ArgoCD désactivé, activable)

```
  Release Please (merge sur main) ──► tag vX.Y.Z ──► build + push image :latest / vX.Y.Z sur GHCR
                                                              │
  Opérateur (toi)                                             │
     │  ./kubernetes/deploy.sh --env prod   ◄─────────────────┘  (déploiement manuel maîtrisé)
     ▼
  helm upgrade --install cofrap + cofrap-frontend  (secrets générés/­injectés via --set)
     ▼
  Cluster K3s prod  (ns cofrap + openfaas-fn)
     ├─ MariaDB + 3 fonctions OpenFaaS + frontend nginx
     └─ VIP MetalLB 192.168.1.241 ──► Cloudflare Tunnel ──► cofrap.home-maurras.fr

  Secrets : créés par le chart (secrets.create=true, défaut) à partir du cache .secrets.prod
```

> **Pourquoi pas ArgoCD en prod ?** Choix volontaire : en prod on veut un déploiement
> **explicite et validé** (pas d'auto-MAJ surprise). `deploy.sh` reste idempotent et
> reproductible.

#### Activer ArgoCD en prod plus tard (optionnel)

Tout est déjà prêt — aucune réécriture nécessaire :

1. Installer ArgoCD + Image Updater sur le cluster prod (cf. [`../docs/runbook-prod.md`](../docs/runbook-prod.md) §9-10).
2. Basculer le chart backend en secrets externes : ajouter `secrets.create: false` dans
   [`values/backend.prod.yaml`](values/backend.prod.yaml) + pré-créer les secrets
   (`./kubernetes/create-secrets.sh --env prod`).
3. Connecter le repo dans ArgoCD (submodules activés) et appliquer l'App-of-Apps prod :
   ```bash
   kubectl apply -f kubernetes/argocd/app-of-apps.prod.yaml
   ```

Les Applications prod ([`argocd/app-cofrap-backend.prod.yaml`](argocd/app-cofrap-backend.prod.yaml),
[`...frontend.prod.yaml`](argocd/app-cofrap-frontend.prod.yaml)) sont déjà configurées avec
`selfHeal: false` (humain dans la boucle) et Image Updater en stratégie **semver** (suit
les tags `vX.Y.Z`, pas les images mobiles). Voir [`argocd/README.md`](argocd/README.md).

## Pré-requis

| Outil      | Version  | Rôle                                                       |
|------------|----------|------------------------------------------------------------|
| `kubectl`  | ≥ 1.28   | Communique avec le cluster                                  |
| `helm`     | ≥ 3.14   | Déploie les charts cofrap + cofrap-frontend                 |
| Un cluster K8s | -    | K3s / minikube / cloud — joignable via `kubectl cluster-info` |
| `python`   | ≥ 3.10 (avec `cryptography`) ou `openssl` | Génération de la clé Fernet |
| MetalLB    | -        | Pour avoir une IP virtuelle stable. Installé automatiquement avec `--install-metallb` si absent. |
| OpenFaaS Community | - | Idem : installé via `--install-openfaas`.                  |

> Le cluster **dev** actuel a déjà MetalLB et OpenFaaS — le script les skippe par défaut.

## Déploiement Phase 1 — scripté

### Linux / macOS / WSL / Git Bash

```bash
chmod +x kubernetes/deploy.sh kubernetes/uninstall.sh    # 1ʳᵉ fois

./kubernetes/deploy.sh --env dev                         # déploie la stack DEV
./kubernetes/deploy.sh --env prod                        # déploie la stack PROD

# Nouveau cluster (MetalLB + OpenFaaS pas encore installés) :
./kubernetes/deploy.sh --env dev --install-metallb --install-openfaas
```

### Windows PowerShell

```powershell
.\kubernetes\deploy.ps1 -Env dev
.\kubernetes\deploy.ps1 -Env prod
.\kubernetes\deploy.ps1 -Env dev -InstallMetallb -InstallOpenfaas
```

### Override d'une variable sans toucher au fichier `env/`

```bash
# Forcer un tag spécifique en prod (au lieu de :latest mobile)
IMAGE_TAG_BACKEND=v2026.3.2 IMAGE_TAG_FRONTEND=v2026.4.0 \
  ./kubernetes/deploy.sh --env prod
```

## Cycle de vie : install / upgrade / uninstall

Le script `deploy.{sh,ps1}` est **idempotent** : tu peux le rejouer autant de fois que tu veux.

- **Premier run** : génère les secrets (Fernet + 2 mots de passe MariaDB), les met en cache dans `kubernetes/.secrets.<env>` (gitignoré), et installe les 2 charts.
- **Runs suivants** : relit le cache → les pods MariaDB conservent leurs données chiffrées.
- **Régénérer les secrets** : `rm kubernetes/.secrets.<env>` puis relancer. ⚠ Les données chiffrées en BDD deviennent illisibles — recréer les comptes utilisateurs.

```bash
./kubernetes/uninstall.sh --env dev                      # supprime backend + frontend + namespace, garde MetalLB + OpenFaaS
./kubernetes/uninstall.sh --env dev --purge-openfaas     # supprime aussi OpenFaaS
./kubernetes/uninstall.sh --env prod --purge-metallb     # supprime aussi MetalLB (⚠ impacte tous les LoadBalancer)
```

## Structure

```
kubernetes/
├── README.md                      # ← vous êtes ici
├── deploy.sh / deploy.ps1         # orchestrateur Phase 1
├── uninstall.sh / uninstall.ps1   # cleanup symétrique
├── env/
│   ├── dev.env                    # IP, hostname, tag, namespace pour DEV
│   └── prod.env
├── loadbalancing/
│   ├── metallb-native.yaml        # MetalLB v0.14.8 (manifest officiel)
│   ├── metallb-pool.dev.yaml      # IPAddressPool 192.168.1.240/32 + L2Advertisement
│   └── metallb-pool.prod.yaml     # IPAddressPool 192.168.1.241/32 + L2Advertisement
├── values/
│   ├── backend.dev.yaml           # overrides Helm — consommés par deploy.sh ET ArgoCD
│   ├── backend.prod.yaml
│   ├── frontend.dev.yaml
│   └── frontend.prod.yaml
└── argocd/                        # Phase 2 — voir kubernetes/argocd/README.md
    ├── README.md
    ├── app-cofrap-backend.{dev,prod}.yaml
    ├── app-cofrap-frontend.{dev,prod}.yaml
    └── app-of-apps.{dev,prod}.yaml
```

## Environnements dev / prod

| Aspect            | dev                                   | prod                                 |
|-------------------|---------------------------------------|--------------------------------------|
| **Mode de déploiement** | **GitOps ArgoCD** (auto-MAJ sur push `dev`) | **Scripté `deploy.sh`** (manuel, validé) — ArgoCD activable |
| **Secrets**       | `secrets.create: false` (pré-créés hors Git) | `secrets.create: true` (créés par le chart via `--set`) |
| Namespace         | `cofrap-dev`                          | `cofrap`                             |
| IP MetalLB (VIP)  | `192.168.1.240`                       | `192.168.1.241`                      |
| Hostname public   | `cofrap-dev.home-maurras.fr`          | `cofrap.home-maurras.fr`             |
| Tag image backend | `dev` (publié par `pre-release.yml`)  | `latest` / `vX.Y.Z` (publié par `release-please.yml`) |
| Tag image frontend| `dev`                                 | `latest` / `vX.Y.Z`                  |
| ImagePullPolicy   | `Always` (tag mobile)                 | `IfNotPresent`                       |
| Image Updater     | stratégie **digest** (`^dev$`)        | stratégie **semver** (`^v\d+\.\d+\.\d+$`) — si ArgoCD activé |
| ArgoCD `selfHeal` | `true` (auto-rollback)                | `false` (humain dans la boucle) — si ArgoCD activé |
| MariaDB PVC       | `1Gi`                                 | `2Gi`                                |
| CORS              | `cofrap-dev.home-maurras.fr` uniquement | `cofrap.home-maurras.fr` uniquement |

Toutes ces valeurs sont éditables dans :
- `kubernetes/env/{dev,prod}.env` — variables shell (IP, hostname, namespace…)
- `kubernetes/values/{backend,frontend}.{dev,prod}.yaml` — overrides Helm (tag, ressources, CORS…)

## Secrets

Les 3 secrets sensibles de la stack — **clé Fernet** (`encryption-key`), **mot de passe applicatif MariaDB**, **mot de passe root MariaDB** — sont :

1. **Générés** par le script au premier run (Fernet via `python -c "from cryptography.fernet import Fernet; ..."`, mots de passe via `openssl rand`).
2. **Mis en cache** dans `kubernetes/.secrets.<env>` (chmod 600, **gitignoré**).
3. **Passés à Helm** via `--set secrets.encryptionKey=...` (pas dans values Git).

> **Perte du fichier `.secrets.<env>` = perte des données chiffrées en BDD.** Sauvegarder dans un vault d'entreprise pour les déploiements long terme.

Pour Phase 2 (ArgoCD), les secrets sortent du Git (cf. [`argocd/README.md`](argocd/README.md)) — on bascule sur Sealed Secrets, External Secrets Operator ou SOPS.

## Phase 2 — GitOps avec ArgoCD

L'objectif final : ArgoCD watche le repo `cofrap-stack`, et chaque push `main` (ou nouveau tag d'image GHCR via Image Updater) **reconcilie automatiquement** le cluster.

Tout est prêt : [`kubernetes/argocd/`](argocd/) contient les manifestes Application + App-of-Apps. Voir le **[guide complet `argocd/README.md`](argocd/README.md)** pour le passage en GitOps.

## Troubleshooting

### Le script échoue sur `kubectl cluster-info`

`KUBECONFIG` ne pointe pas sur le bon cluster. Vérifier :
```bash
kubectl config current-context
kubectl config get-contexts
kubectl config use-context <ton-cluster-dev>
```

### Les pods sont `ImagePullBackOff` après déploiement

Le tag d'image n'existe pas (encore) sur GHCR. Vérifier qu'un push sur `dev` a bien déclenché `pre-release.yml` (côté backend ET frontend), et que le package GHCR est public :
```bash
# Le repo peut être public sans que le package OCI le soit
# → github.com/orgs/<org>/packages → settings → Change package visibility → Public
```

### `helm upgrade` se bloque à `Waiting for...`

Probable manque de ressources cluster. Vérifier :
```bash
kubectl describe pods -n cofrap-dev | grep -A 5 Events
kubectl top nodes
```

### Le hostname public ne répond pas

1. Vérifier que le Service traefik a bien pris l'IP MetalLB :
   ```bash
   kubectl -n kube-system get svc traefik   # EXTERNAL-IP doit être 192.168.1.240 ou .241
   ```
2. Vérifier que l'Ingress est créé :
   ```bash
   kubectl -n cofrap-dev get ingress
   ```
3. Vérifier la config Cloudflare Tunnel : Path doit être **VIDE**, Service = `http://192.168.1.240:80`.

---

## English version

### `kubernetes/` — COFRAP stack deployment

Deploy the **full** COFRAP stack (MariaDB + 3 backend functions + nginx frontend) on Kubernetes with a **single script**, for **dev** and **prod**.

### Quick start

```bash
# Linux / macOS / WSL
./kubernetes/deploy.sh --env dev                          # deploy DEV stack
./kubernetes/deploy.sh --env prod                         # deploy PROD stack
./kubernetes/deploy.sh --env dev --install-metallb --install-openfaas  # fresh cluster

# Windows PowerShell
.\kubernetes\deploy.ps1 -Env dev
.\kubernetes\deploy.ps1 -Env prod -InstallMetallb -InstallOpenfaas

# Teardown
./kubernetes/uninstall.sh --env dev
./kubernetes/uninstall.sh --env prod --purge-openfaas
```

The script is **idempotent**: re-running it preserves the secrets (cached in `kubernetes/.secrets.<env>`, gitignored) so MariaDB encrypted data stays readable.

### dev vs prod

| Aspect       | dev                                   | prod                                |
|--------------|----------------------------------------|-------------------------------------|
| Namespace    | `cofrap-dev`                          | `cofrap`                            |
| MetalLB IP   | `192.168.1.240`                       | `192.168.1.241`                     |
| Hostname     | `cofrap-dev.home-maurras.fr`          | `cofrap.home-maurras.fr`            |
| Image tag    | `dev` (from `pre-release.yml`)        | `latest` (from `release-please.yml`)|

### Phase 2 — GitOps with ArgoCD

When you're ready to switch to GitOps: see [`argocd/README.md`](argocd/README.md). One `kubectl apply` of the App-of-Apps manifest, and ArgoCD takes over — every git push reconciles the cluster automatically. ArgoCD Image Updater also tracks new GHCR tags.

### Structure

See [Structure](#structure) above — identical for both languages.
