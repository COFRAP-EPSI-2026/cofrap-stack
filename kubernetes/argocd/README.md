# `argocd/` — passer la stack COFRAP en GitOps

Manifestes ArgoCD pour déployer et **maintenir automatiquement** la stack COFRAP en GitOps. Une fois en place, plus besoin de `deploy.sh` au quotidien : ArgoCD reconcilie le cluster à chaque push sur `main`.

> 🇬🇧 English version at the end of this file.

## TL;DR

```bash
# 1. Installer ArgoCD (une seule fois par cluster)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Bootstrap : applique l'App-of-Apps de l'env
kubectl apply -f kubernetes/argocd/app-of-apps.dev.yaml
# (ou app-of-apps.prod.yaml pour la prod)

# 3. ArgoCD voit le manifeste racine → installe les 2 Applications enfants
#    (backend + frontend) → chacune déploie son chart Helm. Fini.
```

À partir de là : chaque `git push` sur `main` déclenche une réconciliation. **Plus jamais besoin de `helm upgrade` à la main.**

## Vue d'ensemble

| Fichier                              | Rôle                                                          |
|--------------------------------------|---------------------------------------------------------------|
| `app-of-apps.dev.yaml`               | Application **racine** pour dev — agrège les 2 ci-dessous     |
| `app-of-apps.prod.yaml`              | Application racine pour prod                                  |
| `app-cofrap-backend.dev.yaml`        | Backend cofrap, env dev (release `cofrap-dev`, ns `cofrap-dev`) |
| `app-cofrap-backend.prod.yaml`       | Backend cofrap, env prod                                      |
| `app-cofrap-frontend.dev.yaml`       | Frontend nginx, env dev — avec ArgoCD Image Updater sur `dev` |
| `app-cofrap-frontend.prod.yaml`      | Frontend nginx, env prod — Image Updater sur tags `vX.Y.Z`    |

Toutes les Applications pointent sur le repo `cofrap-stack` et lisent les **mêmes** `values/*.yaml` que `deploy.sh` — une seule source de vérité.

## Pré-requis

1. **Cluster K8s** déjà préparé (MetalLB + OpenFaaS) — typiquement via `./kubernetes/deploy.sh --env <env> --install-metallb --install-openfaas`.
2. **ArgoCD installé** dans le namespace `argocd` (cf. TL;DR ci-dessus).
3. **Submodules Git activés dans ArgoCD** — si tu veux qu'ArgoCD lise `backend/` et `frontend/` qui sont des submodules :
   ```bash
   kubectl -n argocd patch configmap argocd-cm --type merge -p '{
     "data": {
       "resource.exclusions": "",
       "repo.submoduleEnabled": "true"
     }
   }'
   kubectl -n argocd rollout restart deployment argocd-repo-server
   ```
   Ou, plus propre, ajouter au repo dans l'UI ArgoCD : `Settings → Repositories → submodules enabled`.
4. **Secrets pré-créés** dans le bon namespace (voir [§ Secrets](#secrets) plus bas).

## Bootstrap pas-à-pas (env dev)

### 1. Préparer le cluster (une fois)

```bash
# MetalLB + OpenFaaS si pas déjà là (déjà fait sur ton cluster dev actuel)
./kubernetes/deploy.sh --env dev --install-metallb --install-openfaas
# Note : ce premier run crée aussi les secrets dans .secrets.dev — utile pour
# l'étape 2 ci-dessous. Tu peux ensuite supprimer la release Helm "cofrap-dev"
# avec `helm uninstall cofrap-dev -n cofrap-dev` — ArgoCD la recréera.
```

### 2. Créer les secrets pour ArgoCD

ArgoCD ne gère **pas** les secrets — voir [§ Secrets](#secrets). Le plus simple en PoC : pré-créer les Secrets à la main et ArgoCD les ignorera (cf. `ignoreDifferences` dans les Applications).

```bash
# Source le cache produit par deploy.sh
source kubernetes/.secrets.dev

kubectl create namespace openfaas-fn --dry-run=client -o yaml | kubectl apply -f -
kubectl -n openfaas-fn create secret generic encryption-key --from-literal=encryption-key="$ENCRYPTION_KEY"
kubectl -n openfaas-fn create secret generic mariadb-password --from-literal=mariadb-password="$MARIADB_PASSWORD"
```

### 3. Installer ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Récupérer le mot de passe admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# (Optionnel) Port-forward pour l'UI
kubectl -n argocd port-forward svc/argocd-server 8443:443
# → https://localhost:8443  (user: admin)
```

### 4. Bootstrap GitOps

```bash
kubectl apply -f kubernetes/argocd/app-of-apps.dev.yaml
```

Vérifier dans l'UI ArgoCD que les 3 Applications apparaissent et passent `Healthy / Synced` :
- `cofrap-stack-dev` (la racine)
- `cofrap-backend-dev`
- `cofrap-frontend-dev`

## Auto-MAJ sur nouveau tag d'image (ArgoCD Image Updater)

**Objectif** : quand Release Please publie un tag `v2026.X.Y` (backend OU frontend), le cluster est mis à jour **automatiquement** sans toucher à un terminal. Les `pre-release.yml` (branche `dev`) pareil.

### Comment ça marche

```
Push main (feat:) ──► Release Please tag v2026.X.Y ──► CI build & push GHCR
                                                              │
                       ┌──────────────────────────────────────┘
                       ▼ (toutes les 2 min, polling)
              ArgoCD Image Updater
                       │
                       ├─► Détecte nouveau tag matchant le regexp
                       │
                       ▼ (write-back: git)
              git commit + push dans cofrap-stack :
                kubernetes/values/<comp>.prod.yaml
                  image.tag (ou functions.version) ← v2026.X.Y
                       │
                       ▼ (ArgoCD voit le commit en ~30s)
              Reconciliation Helm → kubectl rollout
                       │
                       ▼
              Nouvelle image pullée et déployée
```

### Stratégie par environnement

| Env  | Image watchée                                  | Stratégie    | Filtre tag                   |
|------|-------------------------------------------------|--------------|------------------------------|
| dev  | `ghcr.io/cofrap-epsi-2026/generate-password`    | **digest**   | `^dev$` (tag mobile)          |
| dev  | `ghcr.io/cofrap-epsi-2026/cofrap-frontend`      | **digest**   | `^dev$`                       |
| prod | `ghcr.io/cofrap-epsi-2026/generate-password`    | **semver**   | `^v\d+\.\d+\.\d+$`           |
| prod | `ghcr.io/cofrap-epsi-2026/cofrap-frontend`      | **semver**   | `^v\d+\.\d+\.\d+$`           |

> **Backend = option B** : on ne watche qu'**une** des 3 images backend (`generate-password`). Comme Release Please publie les 3 images au même tag à chaque release, bump du seul champ `functions.version` suffit à redéployer les 3 fonctions de manière cohérente. Zéro modification du chart backend.

### Indépendance backend / frontend

Chaque Application a ses propres annotations et son propre `write-back-target` :
- Release backend → bump uniquement `values/backend.<env>.yaml` → ArgoCD redéploie uniquement les 3 fonctions
- Release frontend → bump uniquement `values/frontend.<env>.yaml` → ArgoCD redéploie uniquement le pod nginx

Pas de couplage. Les 2 repos ont leur propre cycle Release Please.

### Bootstrap ArgoCD Image Updater (1× par cluster)

#### Étape 1 — Créer le PAT GitHub

Sur GitHub, créer un **PAT classique** ([Settings → Developer settings → Personal access tokens → Tokens (classic)](https://github.com/settings/tokens)) ou **fine-grained** :
- **Repo** : `COFRAP-EPSI-2026/cofrap-stack`
- **Permissions** : `contents: write` (fine-grained) ou scope `repo` (classic)
- Optionnel — accès aux packages GHCR si le repo OCI est privé : `read:packages`

**Garder le PAT à portée de main pour l'étape 3.**

#### Étape 2 — Installer Image Updater

```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml
```

#### Étape 3 — Créer le secret git-creds + appliquer la config

```bash
# Replace <PAT> par ton token
kubectl -n argocd create secret generic git-creds \
  --from-literal=username=argocd-image-updater \
  --from-literal=password=<PAT>

# Applique la config Image Updater (registre + identité commit)
kubectl apply -f kubernetes/argocd/image-updater-config.yaml

# Redémarre le pod pour qu'il relise la config
kubectl -n argocd rollout restart deployment argocd-image-updater
```

#### Étape 4 — Déclarer le repo Git dans ArgoCD avec les credentials

ArgoCD lui-même doit pouvoir **pusher** dans cofrap-stack (pas juste pull). Côté UI ArgoCD : **Settings → Repositories → Connect Repo using HTTPS** :
- Repository URL : `https://github.com/COFRAP-EPSI-2026/cofrap-stack.git`
- Username : `argocd-image-updater`
- Password : `<le même PAT que ci-dessus>`
- ✅ **Enable submodules** (sinon le clone ne télécharge pas `backend/` et `frontend/`)

Ou en CLI :
```bash
argocd repo add https://github.com/COFRAP-EPSI-2026/cofrap-stack.git \
  --username argocd-image-updater \
  --password <PAT> \
  --enable-submodule
```

#### Étape 5 — Tester

Vérifier les logs Image Updater :
```bash
kubectl -n argocd logs deploy/argocd-image-updater -f
# Tu dois voir, toutes les 2 min : "Processing image list for application <name>"
```

Quand un nouveau tag est publié :
```
INFO[...] Setting new image to ghcr.io/.../generate-password:v2026.X.Y
INFO[...] Successfully updated image cofrap-backend-prod with new tag
INFO[...] Committing change to git repo
```

Vérifier dans le repo cofrap-stack : un nouveau commit `chore(image-updater): bump ghcr.io/...` doit apparaître ~2 min après la fin de `release-please.yml`. Et dans ArgoCD UI, la Application doit passer en `OutOfSync` puis `Synced/Healthy` 30s plus tard.

### Désactiver le bot pour un env (sans tout supprimer)

Supprime les 7 annotations `argocd-image-updater.argoproj.io/*` de l'Application concernée et `git commit`. Image Updater ignorera cette Application au prochain polling. Pour la réactiver : rétablir les annotations.

## Secrets

⚠ **Les secrets ne doivent JAMAIS être commités dans Git.** Trois approches valables pour ArgoCD :

### Option A — Secrets pré-créés à la main (le plus simple pour un PoC)

C'est ce que font les manifestes actuels (`ignoreDifferences` sur les Secrets `mariadb-password` et `encryption-key` dans `openfaas-fn`). Tu crées les Secrets une fois (étape 2 du bootstrap), ArgoCD ne les touche plus.

**Avantage** : zéro outil supplémentaire.
**Limite** : la rotation est manuelle.

### Option B — Sealed Secrets (Bitnami)

```bash
# Installer le controller
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# Chiffrer un secret avec la clé publique du controller
echo -n 'ma-fernet-key' | kubeseal --raw --name encryption-key --namespace openfaas-fn
# → tu commits ce SealedSecret chiffré dans Git
```

ArgoCD applique le SealedSecret, le controller le déchiffre dans le cluster.

### Option C — External Secrets Operator (ESO)

Le secret réel vit dans un vault externe (AWS Secrets Manager, HashiCorp Vault, Azure Key Vault...). Le cluster va le chercher au démarrage du pod.

Le plus propre en prod, le plus lourd à mettre en place.

## Désinstaller le GitOps (revenir au mode scripté)

```bash
# Supprime l'App-of-Apps → ArgoCD supprime les Applications enfants → les workloads survivent
# car les Applications enfants ont `finalizers` mais sans cascade vers les pods.
kubectl delete -f kubernetes/argocd/app-of-apps.dev.yaml

# Pour vraiment tout supprimer du cluster :
./kubernetes/uninstall.sh --env dev
```

## Troubleshooting

### ArgoCD : `path does not exist`

Le repo n'a pas ses submodules. Activer `submoduleEnabled: true` dans la config repo (cf. § Pré-requis #3).

### ArgoCD : `OutOfSync` permanent sur un Secret

Normal si tu as pré-créé le Secret à la main. Vérifier que la section `ignoreDifferences` de l'Application liste bien le Secret (déjà fait pour `mariadb-password` et `encryption-key`).

### Image Updater ne déclenche pas la MAJ

1. Vérifier qu'il a les credentials Git en écriture : `kubectl -n argocd get secret argocd-image-updater-secret -o yaml`
2. Vérifier les logs : `kubectl -n argocd logs deploy/argocd-image-updater -f`
3. Vérifier que les annotations matchent bien le pattern de tag (`regexp:^dev$` pour dev, `regexp:^v\d+\.\d+\.\d+$` pour prod).

---

## English version

### `argocd/` — switch the COFRAP stack to GitOps

ArgoCD manifests to deploy and **continuously reconcile** the COFRAP stack via GitOps. Once in place, you no longer need `deploy.sh` day-to-day: ArgoCD reconciles the cluster on every push to `main`.

### TL;DR

```bash
# 1. Install ArgoCD (once per cluster)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Bootstrap: apply the env App-of-Apps
kubectl apply -f kubernetes/argocd/app-of-apps.dev.yaml

# 3. ArgoCD reads the root manifest → installs the 2 child Applications
#    (backend + frontend) → each one deploys its Helm chart. Done.
```

From now on: every `git push` to `main` triggers a reconciliation. **No more manual `helm upgrade`.**

### Auto-update on new image tag

The frontend Applications carry [`argocd-image-updater`](https://argocd-image-updater.readthedocs.io/) annotations:
- **dev** follows the `dev` tag (mobile) — every push to `dev` updates the cluster.
- **prod** follows semver tags `vX.Y.Z` only — every Release Please tag updates prod.

This is the full **GitOps loop**: every change (code OR image) goes through Git.

### Secrets

Secrets **never live in Git**. Three valid approaches:
- **A — Pre-created by hand** (simplest for a PoC; the current manifests already `ignoreDifferences` on them)
- **B — Sealed Secrets** (Bitnami controller, encrypted secrets in Git)
- **C — External Secrets Operator** (real secret in AWS/Vault/Azure)

See the French section above for the full step-by-step.
