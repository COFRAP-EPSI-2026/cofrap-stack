# Runbook — Déploiement COFRAP en développement de A à Z

Guide séquentiel **du serveur vide jusqu'à la stack dev avec auto-MAJ sur chaque push**.
À suivre ligne par ligne pour un premier déploiement dev. Compter ~1h si tu n'as
encore rien (K3s, MetalLB, Cloudflare Tunnel, OpenFaaS, ArgoCD, Image Updater).

> **Différence majeure vs [`runbook-prod.md`](runbook-prod.md)** : la dev se met à
> jour automatiquement à **chaque push sur la branche `dev`** des repos backend
> ou frontend. Pas besoin d'attendre une release. Image Updater suit le **digest**
> du tag `:dev` (mobile) au lieu d'un semver.

## Sommaire

- [Vue d'ensemble du flow dev](#vue-densemble-du-flow-dev)
- [Différences clés dev vs prod](#différences-clés-dev-vs-prod)
- [0. Pré-requis matériels](#0-pré-requis-matériels)
- [1. Préparation du serveur (OS)](#1-préparation-du-serveur-os)
- [2. Installation de K3s](#2-installation-de-k3s)
- [3. Installation de MetalLB (pool dev `.240`)](#3-installation-de-metallb-pool-dev-240)
- [4. Cloudflare Zero Trust Tunnel (`cofrap-dev`)](#4-cloudflare-zero-trust-tunnel-cofrap-dev)
- [5. Installation d'OpenFaaS Community](#5-installation-dopenfaas-community)
- [6. Préparation Git + PAT GitHub](#6-préparation-git--pat-github)
- [7. Premier déploiement (Phase 1, manuel)](#7-premier-déploiement-phase-1-manuel)
- [8. Validation du déploiement Phase 1](#8-validation-du-déploiement-phase-1)
- [9. Installation d'ArgoCD](#9-installation-dargocd)
- [10. Installation d'ArgoCD Image Updater (stratégie digest)](#10-installation-dargocd-image-updater-stratégie-digest)
- [11. Préparation des Secrets pour le GitOps](#11-préparation-des-secrets-pour-le-gitops)
- [12. Connexion ArgoCD au repo cofrap-stack](#12-connexion-argocd-au-repo-cofrap-stack)
- [13. Bootstrap GitOps (App-of-Apps dev)](#13-bootstrap-gitops-app-of-apps-dev)
- [14. Test bout-en-bout : push branche `dev` → MAJ auto](#14-test-bout-en-bout--push-branche-dev--maj-auto)
- [15. Workflow dev typique (cycle court)](#15-workflow-dev-typique-cycle-court)
- [16. Recovery / Reset dev](#16-recovery--reset-dev)

---

## Vue d'ensemble du flow dev

À la fin de ce runbook, tu auras ceci qui tourne **automatiquement** :

```
   Tu pushes un commit sur la branche `dev` (backend OU frontend)
         │
         ▼
   pre-release.yml build & push GHCR :
     ghcr.io/cofrap-epsi-2026/<image>:dev          (mobile, même tag)
     ghcr.io/cofrap-epsi-2026/<image>:dev-<sha>    (traçable)
         │
         │ Le tag `:dev` pointe sur un NOUVEAU digest SHA256
         │
         ▼ (toutes les 2 min, polling)
   ArgoCD Image Updater (sur ton cluster dev)
         │
         ├─► Détecte que le digest a changé pour `:dev`
         │
         ▼ (write-back: git)
   git commit + push dans cofrap-stack :
     kubernetes/values/backend.dev.yaml
       version: "dev@sha256:abc123..."   (auto)
         │
         ▼ (~30s, ArgoCD polle Git)
   ArgoCD voit le commit → Helm upgrade → kubectl rollout
         │
         ▼
   Pods redéployés sur le nouveau digest

   Total : ~5-10 min entre `git push origin dev` et la stack dev mise à jour.
```

---

## Différences clés dev vs prod

| Aspect                    | dev                                       | prod                                  |
|---------------------------|--------------------------------------------|---------------------------------------|
| Namespace stack           | `cofrap-dev`                              | `cofrap`                              |
| Release Helm backend      | `cofrap-dev`                              | `cofrap`                              |
| Release Helm frontend     | `cofrap-frontend-dev`                     | `cofrap-frontend`                     |
| IP MetalLB                | `192.168.1.240`                           | `192.168.1.241`                       |
| Hostname public           | `cofrap-dev.home-maurras.fr`              | `cofrap.home-maurras.fr`              |
| Tag image                 | `dev` (mobile)                            | `latest` ou `vX.Y.Z`                  |
| Image Updater stratégie   | **digest** (suit le SHA256)               | **semver** (suit les tags `vX.Y.Z`)   |
| Filtre tag                | `^dev$`                                   | `^v\d+\.\d+\.\d+$`                    |
| Déclencheur auto-MAJ      | **Push sur branche `dev`** (pre-release.yml) | **Merge PR Release Please sur `main`** |
| ArgoCD `selfHeal`         | ✅ **true** (auto-rollback agressif)       | ❌ false (humain dans la boucle)       |
| ArgoCD `pullPolicy`       | `Always` (tag mobile)                     | `IfNotPresent` (tag immuable)         |
| MariaDB PVC               | `1Gi`                                     | `2Gi`                                 |
| CORS origin               | `https://cofrap-dev.home-maurras.fr`      | `https://cofrap.home-maurras.fr`      |
| Cible d'usage             | Itération rapide, casser/réparer OK       | Stabilité avant tout                  |

---

## 0. Pré-requis matériels

| Composant     | Minimum         | Recommandé       |
|---------------|-----------------|------------------|
| CPU           | 2 vCPU          | 2-4 vCPU         |
| RAM           | 4 Go            | 6 Go             |
| Disque        | 25 Go           | 40 Go SSD        |
| OS            | Linux           | Debian 12 / Ubuntu 22.04 |
| Réseau LAN    | IP fixe ou DHCP réservé | Bande passante ≥ 100 Mb/s |

À avoir aussi :
- **Domaine Cloudflare** (le tien : `home-maurras.fr`) + accès Zero Trust
- **Compte GitHub** avec accès à `COFRAP-EPSI-2026/cofrap-stack`
- **PC client** avec `kubectl` + `helm` + SSH vers le serveur

> Dev peut tourner sur la **même machine que prod** (2 clusters K3s = peu vraisemblable car
> 2 hostnames K3s à gérer). Plus simple : un serveur dédié dev (même petite VM ou
> Raspberry Pi 5 8 Go suffit) pour bien isoler des incidents prod.

---

## 1. Préparation du serveur (OS)

### 1.1 Mise à jour + paquets de base

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git jq openssl python3 python3-pip ca-certificates
pip3 install cryptography
```

### 1.2 IP fixe (réservation DHCP ou statique)

```bash
ip addr show
# Note l'IP du serveur, par exemple 192.168.1.51
```

Soit tu fais une **réservation DHCP** sur le routeur (recommandé), soit IP statique
via `/etc/netplan/`.

### 1.3 Firewall (si actif)

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

### 1.4 Désactiver swap

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

---

## 2. Installation de K3s

### 2.1 Préparer la config K3s

```bash
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<'EOF'
disable:
  - servicelb
EOF
```

### 2.2 Installer K3s

```bash
curl -sfL https://get.k3s.io | sh -

sudo systemctl status k3s
sudo kubectl get nodes
```

### 2.3 Kubeconfig pour ton user + PC client

Sur le serveur :
```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config

kubectl get nodes
```

Sur le PC client (recommandé pour piloter depuis ton poste de dev) :
```bash
scp <user>@<ip-serveur-dev>:~/.kube/config ~/.kube/config-cofrap-dev
sed -i "s/127.0.0.1/<ip-serveur-dev>/" ~/.kube/config-cofrap-dev

# Tester
KUBECONFIG=~/.kube/config-cofrap-dev kubectl get nodes

# Optionnel : merger avec le kubeconfig prod pour switcher entre les deux
KUBECONFIG=~/.kube/config:~/.kube/config-cofrap-dev kubectl config view --flatten > ~/.kube/config-merged
mv ~/.kube/config-merged ~/.kube/config
kubectl config get-contexts
kubectl config use-context <ton-dev-context>
```

> Bonus : installer [`kubectx`](https://github.com/ahmetb/kubectx) pour switcher dev/prod en une commande (`kubectx dev` / `kubectx prod`).

---

## 3. Installation de MetalLB (pool dev `.240`)

### 3.1 Installer MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

kubectl -n metallb-system wait --for=condition=Ready pod --all --timeout=120s
```

### 3.2 Cloner cofrap-stack + appliquer le pool dev

```bash
git clone --recurse-submodules https://github.com/COFRAP-EPSI-2026/cofrap-stack.git
cd cofrap-stack

# Pool dev → 192.168.1.240
kubectl apply -f kubernetes/loadbalancing/metallb-pool.dev.yaml

# Vérifier
kubectl get ipaddresspools -n metallb-system
# NAME       AUTO ASSIGN   AVOID BUGGY IPS   ADDRESSES
# lan-pool   true          false             ["192.168.1.240/32"]
```

### 3.3 Vérifier que traefik a pris le VIP `.240`

```bash
kubectl get svc -n kube-system traefik
# NAME      TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)
# traefik   LoadBalancer   10.43.x.y     192.168.1.240   80:30000/TCP,443:30001/TCP
```

```bash
# Test depuis un autre poste du LAN
ping 192.168.1.240
curl http://192.168.1.240/   # → 404 attendu (rien de déployé encore)
```

---

## 4. Cloudflare Zero Trust Tunnel (`cofrap-dev`)

### Deux choix possibles

**Option A — Réutiliser le tunnel prod existant** (plus simple si tu as un seul serveur cloudflared) : juste ajouter un nouveau **public hostname**.

**Option B — Créer un tunnel dédié dev** : plus propre si dev tourne sur un autre serveur que prod (cloudflared dédié à chaque cluster).

### Option A — Ajouter un public hostname au tunnel existant

1. Dashboard Cloudflare Zero Trust → **Networks → Tunnels → ton tunnel existant**
2. Onglet **Public Hostnames → Add a public hostname**

| Champ      | Valeur                                |
|------------|---------------------------------------|
| Subdomain  | `cofrap-dev`                          |
| Domain     | `home-maurras.fr`                     |
| **Path**   | **(VIDE — ne RIEN mettre)**           |
| Service    | Type `HTTP` + URL `192.168.1.240:80`  |

3. **Save**.

### Option B — Tunnel dédié dev

```bash
# Sur la machine cloudflared dev
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb

# Créer le tunnel dans le dashboard Cloudflare (nom : cofrap-dev-home),
# récupérer le token, puis :
sudo cloudflared service install <TOKEN>
sudo systemctl status cloudflared
```

Puis ajouter le public hostname `cofrap-dev.home-maurras.fr` → `192.168.1.240:80`, Path vide.

### 4.x Vérifier

```bash
curl -I https://cofrap-dev.home-maurras.fr/
# HTTP/2 404
# server: cloudflare
```

404 + `server: cloudflare` = tunnel OK, Traefik répond, rien de déployé. ✅

---

## 5. Installation d'OpenFaaS Community

```bash
helm repo add openfaas https://openfaas.github.io/faas-netes/
helm repo update

kubectl create namespace openfaas    --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace openfaas-fn --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install openfaas openfaas/openfaas \
  --namespace openfaas \
  --set functionNamespace=openfaas-fn \
  --set generateBasicAuth=true \
  --wait --timeout 5m
```

### 5.1 Mot de passe admin OpenFaaS

```bash
kubectl -n openfaas get secret basic-auth \
  -o jsonpath='{.data.basic-auth-password}' | base64 -d ; echo
```

### 5.2 Vérifier

```bash
kubectl get pods -n openfaas
```

---

## 6. Préparation Git + PAT GitHub

### 6.1 cofrap-stack (déjà cloné au step 3.2)

```bash
cd cofrap-stack
bash scripts/init.sh   # si tu as cloné sans --recurse-submodules
```

### 6.2 PAT GitHub

Même PAT que pour la prod (si tu en as déjà un, **réutilise-le** — un seul PAT
suffit pour les deux envs car ils partagent le même repo cofrap-stack).

**Fine-grained** (préféré) :
- Resource owner : `COFRAP-EPSI-2026`
- Repository : `cofrap-stack`
- Permissions : **Contents: Read and write**
- Expiration : 90 jours+

**Classic** : scope `repo`.

**Copier le token** — utile aux steps 10 et 12.

### 6.3 Packages GHCR publics

Sur https://github.com/orgs/COFRAP-EPSI-2026/packages, vérifier que `cofrap-frontend`, `generate-password`, `generate-2fa`, `authenticate-user` sont **Public**. Sinon `Settings → Change visibility → Public`.

---

## 7. Premier déploiement (Phase 1, manuel)

### 7.1 Lancer `deploy.sh --env dev`

```bash
cd cofrap-stack

# Linux / WSL
./kubernetes/deploy.sh --env dev
```

Ce qu'il fait :
1. Vérifie cluster
2. Skip MetalLB + OpenFaaS (déjà installés)
3. **Génère** les secrets dev → `kubernetes/.secrets.dev` (chmod 600, gitignoré)
4. `helm upgrade --install cofrap-dev` (release dans ns `cofrap-dev`)
5. `helm upgrade --install cofrap-frontend-dev`
6. Affiche le récap

### 7.2 Vérifier les pods

```bash
kubectl get pods -n cofrap-dev
# mariadb-0                            1/1 Running

kubectl get pods -n openfaas-fn -l 'faas_function'
# generate-password-xxx                1/1 Running
# generate-2fa-xxx                     1/1 Running
# authenticate-user-xxx                1/1 Running

kubectl get pods -n cofrap-dev -l 'app.kubernetes.io/name=cofrap-frontend'
# cofrap-frontend-dev-xxx              1/1 Running
```

> **Note dev** : `.secrets.dev` est différent de `.secrets.prod`. Garder les deux dans
> ton vault si tu vas restaurer dev plus tard. Sinon, dev est moins critique (pas de
> vraies données utilisateurs).

---

## 8. Validation du déploiement Phase 1

### 8.1 Test sur le VIP

```bash
curl -H 'Host: cofrap-dev.home-maurras.fr' http://192.168.1.240/healthz
# → "ok"
```

### 8.2 Test depuis Cloudflare Tunnel

```bash
curl -I https://cofrap-dev.home-maurras.fr/
# HTTP/2 200
# server: cloudflare

# Tester l'API
curl -sX POST https://cofrap-dev.home-maurras.fr/api/function/generate-password \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice-dev-test"}' | jq '{username, gendate}'
```

### 8.3 Ouvrir l'UI dans le navigateur

→ https://cofrap-dev.home-maurras.fr — tu dois voir la SPA Vue 3.
→ Créer un compte, scanner le QR 2FA, se connecter. Si OK : Phase 1 dev validée.

---

## 9. Installation d'ArgoCD

Si tu **as déjà ArgoCD pour la prod** (même cluster que dev impossible, mais imaginons
un setup multi-cluster où un ArgoCD central gère les deux), **saute ce step** et
ajoute juste les Applications dev (step 13).

Sinon (ArgoCD dédié dev) :

```bash
kubectl create namespace argocd
# IMPORTANT : --server-side évite "Too long: may not be more than 262144 bytes"
# sur la CRD ApplicationSet (~280 KB, dépasse la limite K8s sur les annotations
# côté kubectl apply client-side).
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl -n argocd wait --for=condition=Ready pod --all --timeout=300s

# Optionnel : on n'utilise pas ApplicationSet dans le setup COFRAP — autant
# libérer le pod et nettoyer les logs.
kubectl -n argocd scale deployment argocd-applicationset-controller --replicas=0

# Mot de passe admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
```

### 9.1 Exposer l'UI ArgoCD (recommandé : Ingress + tunnel)

```bash
# Créer un Ingress pour ArgoCD
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - host: argocd-dev.home-maurras.fr
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

# Côté Cloudflare Tunnel : ajouter un public hostname `argocd-dev.home-maurras.fr` → http://192.168.1.240:80, Path vide.
```

Alternative simple : `kubectl port-forward -n argocd svc/argocd-server 8443:443` puis https://localhost:8443.

---

## 10. Installation d'ArgoCD Image Updater (stratégie digest)

C'est ici que ça diverge **fortement** de la prod : on suit le **digest** du tag
mobile `:dev` au lieu de chercher des nouveaux tags semver.

```bash
# Le manifest est sous config/install.yaml (PAS manifests/ — ancien chemin = 404)
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/config/install.yaml

kubectl -n argocd rollout status deployment argocd-image-updater-controller-controller --timeout=120s
```

### 10.1 Secret git-creds avec le PAT (du step 6.2)

```bash
kubectl -n argocd create secret generic git-creds \
  --from-literal=username=argocd-image-updater \
  --from-literal=password=<PAT>
```

### 10.2 Appliquer la config Image Updater

```bash
kubectl apply -f kubernetes/argocd/image-updater-config.yaml

kubectl -n argocd rollout restart deployment argocd-image-updater-controller
```

### 10.3 Vérifier les logs

```bash
kubectl -n argocd logs deploy/argocd-image-updater-controller -f
# time="..." msg="Starting argocd-image-updater"
# time="..." msg="Loaded 0 image(s) to be considered for update"
#   ^^^ Normal pour l'instant, on connecte les Apps au step 13
```

### Comment fonctionne la stratégie `digest`

Le tag `:dev` est **mobile** : à chaque push sur la branche dev, `pre-release.yml`
re-build et re-push `ghcr.io/.../<image>:dev`, mais le digest SHA256 du tag change.

Image Updater configuré en `update-strategy: digest` :
1. Polle GHCR pour résoudre `:dev` → `sha256:<digest>`
2. Compare avec le digest qu'il a déjà vu
3. Si différent → commit dans `values/<comp>.dev.yaml` :
   ```yaml
   version: "dev@sha256:abc123def456..."   # ← bumpé auto
   ```
4. ArgoCD reconcile, K3s pull le nouveau digest, pod redéployé

Le mécanisme est précâblé dans `kubernetes/argocd/app-cofrap-*.dev.yaml` — rien à modifier.

---

## 11. Préparation des Secrets pour le GitOps

Comme en prod, les Secrets ne vivent pas en Git. Pré-création depuis le cache Phase 1.

```bash
source kubernetes/.secrets.dev

kubectl create namespace openfaas-fn --dry-run=client -o yaml | kubectl apply -f -

kubectl -n openfaas-fn create secret generic encryption-key \
  --from-literal=encryption-key="$ENCRYPTION_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n openfaas-fn create secret generic mariadb-password \
  --from-literal=mariadb-password="$MARIADB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
```

> En dev, tu peux te permettre de **régénérer** les secrets de temps en temps (un
> `rm kubernetes/.secrets.dev` + relance de `deploy.sh --env dev` régénère tout).
> Ça reset MariaDB → comptes utilisateurs perdus, normal en dev.

---

## 12. Connexion ArgoCD au repo cofrap-stack

Si tu **n'as pas déjà connecté le repo** (cas : ArgoCD dev séparé de prod), faire comme en prod :

### Via l'UI ArgoCD

1. **Settings → Repositories → CONNECT REPO**
2. **HTTPS** / Git / `default`
3. URL : `https://github.com/COFRAP-EPSI-2026/cofrap-stack.git`
4. Username : `argocd-image-updater`
5. Password : **le PAT du step 6.2**
6. ✅ **Enable submodules** ← INDISPENSABLE
7. **CONNECT** → `Connection Status: Successful`

### Via CLI

```bash
argocd repo add https://github.com/COFRAP-EPSI-2026/cofrap-stack.git \
  --username argocd-image-updater \
  --password <PAT> \
  --enable-submodule
```

---

## 13. Bootstrap GitOps (App-of-Apps dev)

### 13.1 Désinstaller les Helm releases Phase 1

Pour éviter que ArgoCD ait à adopter des releases existantes (= `OutOfSync` parasites) :

```bash
helm uninstall cofrap-dev          -n cofrap-dev
helm uninstall cofrap-frontend-dev -n cofrap-dev

# Les pods disparaissent, les PVC MariaDB + Secrets restent (heureusement)
kubectl get pvc -n cofrap-dev
kubectl get secret -n openfaas-fn
```

### 13.2 Apply l'App-of-Apps dev

```bash
kubectl apply -f kubernetes/argocd/app-of-apps.dev.yaml
```

### 13.3 Suivre la création

```bash
kubectl -n argocd get applications -w
# (Ctrl+C quand les 3 sont Synced/Healthy)

# Ou dans l'UI ArgoCD : 3 cartes apparaissent :
#   - cofrap-stack-dev
#   - cofrap-backend-dev
#   - cofrap-frontend-dev
```

Les Apps doivent passer en **`Synced` + `Healthy`** en ~1-2 min.

### 13.4 Re-tester

```bash
curl -I https://cofrap-dev.home-maurras.fr/
# HTTP/2 200
```

**Tu es en GitOps complet en dev.** À partir de maintenant, ne modifies plus
les pods à la main — passe par Git ou laisse Image Updater faire son taf.

---

## 14. Test bout-en-bout : push branche `dev` → MAJ auto

### 14.1 Vérifier que Image Updater voit les Apps dev

```bash
kubectl -n argocd logs deploy/argocd-image-updater-controller | tail -20
# time="..." msg="Loaded 2 image(s) to be considered for update"
# time="..." msg="Processing image list for application cofrap-backend-dev"
# time="..." msg="Processing image list for application cofrap-frontend-dev"
```

### 14.2 Test rapide : push un commit sur la branche `dev`

Sur ton repo `cofrap-backend` (en local sur ton PC dev) :

```bash
cd cofrap-backend
git checkout dev
git pull

# Petit commit cosmétique pour déclencher pre-release.yml
echo "// test bump $(date)" >> functions/generate-password/main.py
git commit -am "chore(test): verify dev GitOps loop"
git push origin dev
```

### 14.3 Observer le pipeline

**Côté GitHub** (~3-5 min) :
1. Workflow `pre-release.yml` se lance
2. Build + push des 3 images backend sur GHCR avec tag `:dev` (nouveau digest)

**Côté cluster** (~2-3 min après la fin du workflow) :
```bash
# Logs Image Updater — tu dois voir :
kubectl -n argocd logs deploy/argocd-image-updater-controller -f
# time="..." msg="Setting new image to ghcr.io/cofrap-epsi-2026/generate-password:dev@sha256:..."
# time="..." msg="Committing 1 parameter update(s) for application cofrap-backend-dev"
# time="..." msg="Successfully updated the live application spec"

# Le commit dans cofrap-stack
cd ~/cofrap-stack
git log -3 --oneline kubernetes/values/backend.dev.yaml
# ad12345 chore(image-updater): bump ghcr.io/.../generate-password → dev@sha256:abc...
```

**ArgoCD reconcile** (~30s après le commit) :
```bash
kubectl -n argocd get app cofrap-backend-dev -o jsonpath='{.status.sync.status}'
# Synced

# Les pods sont rollés
kubectl get pods -n openfaas-fn -l 'faas_function' -w
# Tu vois les anciens Terminating et les nouveaux Running
```

**Total** : ~5-10 min entre `git push origin dev` et les pods dev sur la nouvelle version. 🎉

### 14.4 Cas frontend

Pareil : push sur `cofrap-frontend@dev` → `pre-release.yml` → image `:dev` → Image Updater bump `kubernetes/values/frontend.dev.yaml` → ArgoCD reconcile → pod frontend rollé.

---

## 15. Workflow dev typique (cycle court)

Une fois le GitOps en place, ton workflow quotidien devient :

### 15.1 Itérer sur une feature backend

```bash
cd cofrap-backend
git checkout dev
git pull

# Coder ta feature, lancer les tests en local
ruff check --fix . && ruff format .
pytest

# Push direct sur dev (ou via PR si tu veux la review)
git commit -am "feat: <description>"
git push origin dev
```

→ ~5-10 min après, ta feature tourne sur https://cofrap-dev.home-maurras.fr — testable end-to-end.

### 15.2 Itérer sur une feature frontend

```bash
cd cofrap-frontend
git checkout dev
git pull

yarn check:all   # lint + format + type-check + i18n + build + bundle-size
git commit -am "feat: <description>"
git push origin dev
```

→ Pareil, ~5-10 min jusqu'à la dev live.

### 15.3 Surveiller en parallèle

Garde un terminal avec :
```bash
# Cycle des images sur dev
kubectl get pods -n openfaas-fn -l 'faas_function' -w     # backend
kubectl get pods -n cofrap-dev -l 'app.kubernetes.io/name=cofrap-frontend' -w   # frontend

# Voir les commits qui arrivent en GitOps
watch -n 60 'cd ~/cofrap-stack && git pull --quiet && git log -3 --oneline kubernetes/values/'
```

### 15.4 Tester un commit précis (debug)

Si tu veux savoir QUEL commit GHCR `:dev` tourne en ce moment :

```bash
kubectl get pod -n openfaas-fn -l 'faas_function=generate-password' \
  -o jsonpath='{.items[0].spec.containers[0].image}'
# ghcr.io/cofrap-epsi-2026/generate-password:dev@sha256:abc123...

# Le tag `dev-<sha>` pointe vers le SHA git correspondant (publié en parallèle par pre-release.yml)
# → tu peux retrouver le commit exact en cherchant ce digest sur GHCR.
```

### 15.5 Forcer une MAJ immédiate (sans attendre Image Updater)

Si tu pushes 3 commits coup sur coup et que tu veux que ça monte tout de suite :

```bash
# Forcer Image Updater à re-scanner maintenant
kubectl -n argocd rollout restart deployment argocd-image-updater-controller

# Ou forcer ArgoCD à re-syncer (si Image Updater a déjà commit)
argocd app sync cofrap-backend-dev
argocd app sync cofrap-frontend-dev
```

### 15.6 Désactiver temporairement l'auto-MAJ

Si tu veux geler dev pour une démo et empêcher les pushes auto :

```bash
# Suspendre la sync ArgoCD
argocd app set cofrap-backend-dev --sync-policy none
argocd app set cofrap-frontend-dev --sync-policy none

# Quand t'as fini, réactiver l'auto-sync
argocd app set cofrap-backend-dev --sync-policy automated --auto-prune --self-heal
argocd app set cofrap-frontend-dev --sync-policy automated --auto-prune --self-heal
```

---

## 16. Recovery / Reset dev

Dev étant moins critique que prod, **n'hésite pas à tout reset** si quelque chose
part en sucette. Procédures rapides :

### 16.1 Reset complet (garde les secrets)

```bash
./kubernetes/uninstall.sh --env dev
# (NE supprime PAS le cache .secrets.dev par défaut sans --keep-secrets)

# Re-déployer
./kubernetes/deploy.sh --env dev
```

### 16.2 Reset complet **avec** régénération des secrets

```bash
./kubernetes/uninstall.sh --env dev
rm kubernetes/.secrets.dev          # ⚠ tu perds les données chiffrées (comptes utilisateurs)
./kubernetes/deploy.sh --env dev    # régénère des secrets neufs
```

### 16.3 Reset uniquement Image Updater (s'il foire les commits)

```bash
kubectl -n argocd rollout restart deployment argocd-image-updater-controller

# Logs pour comprendre
kubectl -n argocd logs deploy/argocd-image-updater-controller -f
```

### 16.4 Reset uniquement ArgoCD (sans toucher au cluster)

```bash
# Suspendre toutes les apps (sinon ArgoCD va re-créer tout au reboot)
argocd app set cofrap-backend-dev --sync-policy none
argocd app set cofrap-frontend-dev --sync-policy none

# Détruire / recréer Argo
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Re-bootstrap GitOps
kubectl apply -f kubernetes/argocd/app-of-apps.dev.yaml
```

### 16.5 Reset uniquement les pods dev (sans toucher à la config)

```bash
kubectl delete pods -n cofrap-dev --all
kubectl delete pods -n openfaas-fn -l 'faas_function'
# Les Deployments recréent tout en ~30s
```

### 16.6 Cluster K3s qui foire complètement

```bash
# Désinstaller K3s
/usr/local/bin/k3s-uninstall.sh

# Recommencer depuis le step 2 du runbook (à condition d'avoir gardé .secrets.dev !)
```

---

## Aller plus loin

- 🚀 [`runbook-prod.md`](runbook-prod.md) — équivalent prod (focus releases stables `vX.Y.Z`)
- 📋 [`cheatsheet.md`](cheatsheet.md) — commandes courantes (kubectl, helm, k3s, argocd…)
- 🏗️ [`kubernetes/README.md`](../kubernetes/README.md) — architecture + Phase 1
- 🤖 [`kubernetes/argocd/README.md`](../kubernetes/argocd/README.md) — Phase 2 (GitOps + Image Updater)
- 🔧 [`backend/docs/fr/development.md`](../backend/docs/fr/development.md) — workflow dev backend
- 🎨 [`frontend/docs/fr/development.md`](../frontend/docs/fr/development.md) — workflow dev frontend
