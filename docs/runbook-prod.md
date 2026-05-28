# Runbook — Déploiement COFRAP en production de A à Z

Guide séquentiel **du serveur vide jusqu'à la stack en prod avec GitOps automatique**.
À suivre ligne par ligne pour un premier déploiement. Compter ~1h-1h30 si tu n'as
encore rien (K3s, MetalLB, Cloudflare Tunnel, OpenFaaS, ArgoCD, Image Updater).

> Pour les opérations ponctuelles après le déploiement, voir [`cheatsheet.md`](cheatsheet.md).
> Pour comprendre le « pourquoi » des choix d'archi, voir [`kubernetes/README.md`](../kubernetes/README.md) et [`kubernetes/argocd/README.md`](../kubernetes/argocd/README.md).

## Sommaire

- [Vue d'ensemble du flow final](#vue-densemble-du-flow-final)
- [0. Pré-requis matériels](#0-pré-requis-matériels)
- [1. Préparation du serveur (OS)](#1-préparation-du-serveur-os)
- [2. Installation de K3s](#2-installation-de-k3s)
- [3. Installation de MetalLB](#3-installation-de-metallb)
- [4. Cloudflare Zero Trust Tunnel](#4-cloudflare-zero-trust-tunnel)
- [5. Installation d'OpenFaaS Community](#5-installation-dopenfaas-community)
- [6. Préparation Git + PAT GitHub](#6-préparation-git--pat-github)
- [7. Premier déploiement (Phase 1, manuel)](#7-premier-déploiement-phase-1-manuel)
- [8. Validation du déploiement Phase 1](#8-validation-du-déploiement-phase-1)
- [9. Installation d'ArgoCD](#9-installation-dargocd)
- [10. Installation d'ArgoCD Image Updater](#10-installation-dargocd-image-updater)
- [11. Préparation des Secrets pour le GitOps](#11-préparation-des-secrets-pour-le-gitops)
- [12. Connexion ArgoCD au repo cofrap-stack](#12-connexion-argocd-au-repo-cofrap-stack)
- [13. Bootstrap GitOps (App-of-Apps)](#13-bootstrap-gitops-app-of-apps)
- [14. Test bout-en-bout du flow auto](#14-test-bout-en-bout-du-flow-auto)
- [15. Opérations courantes en prod](#15-opérations-courantes-en-prod)
- [16. Recovery / Disaster](#16-recovery--disaster)

---

## Vue d'ensemble du flow final

À la fin de ce runbook, tu auras ceci qui tourne **automatiquement** :

```
   GitHub PR (feat: sur cofrap-backend)
         │
         ▼ merge sur main
   Release Please tag v2026.X.Y
         │
         ▼
   release-please.yml build & push GHCR
   ghcr.io/cofrap-epsi-2026/<3 fonctions>:v2026.X.Y
         │                            (toutes les 2 min)
         ▼ ───────────────► ArgoCD Image Updater (sur ton cluster)
                                     │
                                     │ commit auto via PAT
                                     ▼
                            cofrap-stack/kubernetes/values/backend.prod.yaml
                              version: "v2026.X.Y"   (auto)
                                     │
                                     │ (toutes les 3 min)
                                     ▼
                              ArgoCD (sur ton cluster)
                                     │ détecte le commit
                                     ▼
                              Helm upgrade → kubectl rollout
                                     │
                                     ▼
                            Pods redéployés sur la nouvelle version

   Total : ~5-10 min entre le merge GitHub et la prod live.
```

---

## 0. Pré-requis matériels

| Composant     | Minimum         | Recommandé      |
|---------------|-----------------|-----------------|
| CPU           | 2 vCPU          | 4 vCPU          |
| RAM           | 4 Go            | 8 Go            |
| Disque        | 30 Go           | 50 Go SSD       |
| OS            | Linux           | Debian 12 / Ubuntu 22.04 |
| Réseau LAN    | IP fixe ou DHCP réservé | Bande passante ≥ 100 Mb/s |

À avoir aussi :
- **Domaine Cloudflare** (le tien : `home-maurras.fr`) + compte Cloudflare Zero Trust (gratuit)
- **Compte GitHub** avec accès à `COFRAP-EPSI-2026/cofrap-stack`
- **PC client** pour piloter (avec `kubectl` + `helm` + un SSH vers le serveur)

---

## 1. Préparation du serveur (OS)

### 1.1 Mise à jour + paquets de base

```bash
# Sur le serveur, en SSH
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git jq openssl python3 python3-pip ca-certificates
pip3 install cryptography           # pour générer la clé Fernet en local
```

### 1.2 IP fixe (réservation DHCP recommandée — plus simple)

Vérifier l'IP actuelle :
```bash
ip addr show
# Note l'IP du serveur sur le LAN, par exemple 192.168.1.50
```

Aller dans l'interface de ton routeur → réserver cette IP pour la MAC du serveur.
(Alternative : configurer une IP statique dans `/etc/netplan/` ou équivalent — plus
fragile, à éviter si tu peux passer par le routeur.)

### 1.3 Firewall

Si `ufw` est actif, ouvrir les ports K8s :
```bash
sudo ufw allow 6443/tcp   # API K8s (optionnel — uniquement pour kubectl à distance)
sudo ufw allow 80/tcp     # HTTP (Ingress)
sudo ufw allow 443/tcp    # HTTPS (Ingress)
sudo ufw status
```

Sinon, ne pas activer `ufw` — K3s tourne sans souci avec firewall désactivé sur un homelab.

### 1.4 Désactiver swap (recommandé K8s)

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

---

## 2. Installation de K3s

K3s = Kubernetes léger, parfait pour homelab. **5 minutes top chrono.**

### 2.1 Préparer la config K3s (désactiver ServiceLB)

ServiceLB est le LoadBalancer intégré de K3s. **On le désactive** pour utiliser
MetalLB à la place (qui donne une IP virtuelle stable).

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

# Vérifier
sudo systemctl status k3s
sudo kubectl get nodes
# NAME            STATUS   ROLES                  AGE   VERSION
# <ton-serveur>   Ready    control-plane,master   30s   v1.31.x+k3s1
```

### 2.3 Récupérer le kubeconfig (pour kubectl sans sudo + depuis le PC client)

```bash
# Sur le serveur — copier le kubeconfig pour ton user
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config

# Tester sans sudo
kubectl get nodes
```

**Depuis ton PC client** (Linux/Mac/WSL) — récupérer le kubeconfig du serveur :

```bash
# scp le fichier
scp <user>@<ip-serveur>:~/.kube/config ~/.kube/config-cofrap-prod

# Remplacer l'IP 127.0.0.1 par l'IP LAN du serveur
sed -i "s/127.0.0.1/<ip-serveur>/" ~/.kube/config-cofrap-prod

# Tester
KUBECONFIG=~/.kube/config-cofrap-prod kubectl get nodes
```

Pour utiliser en permanence : `export KUBECONFIG=~/.kube/config-cofrap-prod` (ou
le merger dans `~/.kube/config` si tu as plusieurs clusters).

---

## 3. Installation de MetalLB

MetalLB donne une **IP virtuelle stable** sur ton LAN au Service `traefik` (le
LoadBalancer / Ingress controller). Cette IP servira de cible au Cloudflare Tunnel.

### 3.1 Installer MetalLB (manifest natif — pas le chart Helm)

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

# Attendre que tout soit Ready (peut prendre 30-60s)
kubectl -n metallb-system wait --for=condition=Ready pod --all --timeout=120s
```

### 3.2 Configurer le pool d'IPs pour la prod (192.168.1.241)

Cloner cofrap-stack d'abord (si pas déjà fait) :
```bash
git clone --recurse-submodules https://github.com/COFRAP-EPSI-2026/cofrap-stack.git
cd cofrap-stack
```

Puis appliquer le pool prod :
```bash
kubectl apply -f kubernetes/loadbalancing/metallb-pool.prod.yaml

# Vérifier
kubectl get ipaddresspools -n metallb-system
# NAME       AUTO ASSIGN   AVOID BUGGY IPS   ADDRESSES
# lan-pool   true          false             ["192.168.1.241/32"]
```

### 3.3 Vérifier que traefik a pris le VIP

```bash
kubectl get svc -n kube-system traefik
# NAME      TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)
# traefik   LoadBalancer   10.43.x.y     192.168.1.241   80:30000/TCP,443:30001/TCP
```

> Si `EXTERNAL-IP` reste `<pending>` après 1 min : vérifier que `metallb-pool.prod.yaml` a bien été apply, et `kubectl logs -n metallb-system -l app=metallb,component=speaker` pour debug.

### 3.4 Test : depuis un autre poste du LAN

```bash
ping 192.168.1.241
curl -k http://192.168.1.241/   # Attendu : 404 not found (Traefik répond, pas d'Ingress encore)
```

---

## 4. Cloudflare Zero Trust Tunnel

Le tunnel expose `cofrap.home-maurras.fr` → `192.168.1.241:80` sans ouvrir de port côté box.

### 4.1 Créer un tunnel dans le dashboard Cloudflare

1. Va sur https://one.dash.cloudflare.com
2. **Networks → Tunnels → Create a tunnel**
3. **Cloudflared** → nom du tunnel : `cofrap-home`
4. **Save** → tu vois la commande d'install. **Copier le token.**

### 4.2 Installer cloudflared sur le serveur (ou ailleurs sur le LAN)

> Astuce : tu peux mettre cloudflared sur **une autre VM** que ton cluster K3s.
> C'est mieux séparé (si tu redéploies K3s, le tunnel reste up).

```bash
# Sur Debian/Ubuntu
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb

# Authentifier avec le token Cloudflare et lancer en service systemd
sudo cloudflared service install <TOKEN>

# Vérifier
sudo systemctl status cloudflared
```

### 4.3 Configurer le public hostname

Retour dans le dashboard Cloudflare → ton tunnel → **Public Hostnames → Add a public hostname** :

| Champ      | Valeur                       |
|------------|------------------------------|
| Subdomain  | `cofrap`                     |
| Domain     | `home-maurras.fr`            |
| **Path**   | **(VIDE — ne RIEN mettre)**  |
| Service    | Type `HTTP` + URL `192.168.1.241:80` |

⚠ **Le champ Path doit rester totalement vide.** Une valeur (même `^/`) restreint
le tunnel à un chemin spécifique et casse le routing → `ERR_SSL_VERSION_OR_CIPHER_MISMATCH`.

**Save.** Le DNS Cloudflare est créé automatiquement (CNAME proxied vers le tunnel).

### 4.4 Vérifier (sans backend encore — tu dois avoir un 404)

```bash
curl -I https://cofrap.home-maurras.fr/
# HTTP/2 404
# server: cloudflare
```

Si tu vois `404` avec `server: cloudflare`, c'est PARFAIT : le tunnel fonctionne, mais Traefik n'a pas encore d'Ingress qui match → c'est attendu, on déploie au step 7.

---

## 5. Installation d'OpenFaaS Community

OpenFaaS héberge les 3 fonctions Python du backend. Une seule fois par cluster.

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

### 5.1 Récupérer le mot de passe admin (à GARDER)

```bash
kubectl -n openfaas get secret basic-auth \
  -o jsonpath='{.data.basic-auth-password}' | base64 -d ; echo
# → copier ce mot de passe dans ton gestionnaire de mots de passe
```

### 5.2 Vérifier qu'OpenFaaS tourne

```bash
kubectl get pods -n openfaas
# Tous en Running
```

---

## 6. Préparation Git + PAT GitHub

### 6.1 Cloner cofrap-stack (si pas fait au step 3.2)

```bash
git clone --recurse-submodules https://github.com/COFRAP-EPSI-2026/cofrap-stack.git
cd cofrap-stack
bash scripts/init.sh                # init des submodules si tu as cloné sans --recurse
```

### 6.2 Créer un PAT GitHub (pour Image Updater)

Aller sur https://github.com/settings/tokens (classic) ou https://github.com/settings/personal-access-tokens/new (fine-grained — préféré) :

**Fine-grained** :
- Resource owner : `COFRAP-EPSI-2026`
- Repository access : Only select repositories → `cofrap-stack`
- Permissions : Repository permissions → **Contents: Read and write**
- Expiration : 90 jours (ou plus si tu veux pas renouveler)

**Classic** :
- Scope : `repo` (full)

**Copier le token** (commence par `github_pat_...` ou `ghp_...`) → garder précieusement. Tu en auras besoin au step 10 + 12.

### 6.3 Si les packages OCI GHCR sont privés

Vérifier sur https://github.com/orgs/COFRAP-EPSI-2026/packages : les 4 packages
(`cofrap-frontend`, `generate-password`, `generate-2fa`, `authenticate-user`)
doivent être **Public**. Sinon, sur chaque package → **Package settings → Change visibility → Public**. Sans ça, K3s ne peut pas pull les images sans imagePullSecret.

---

## 7. Premier déploiement (Phase 1, manuel)

On va d'abord déployer **manuellement** avec `deploy.sh`. Ça permet :
- De valider que le cluster est sain
- De générer les secrets (Fernet + 2 mots de passe MariaDB) **une seule fois**, mis en cache dans `kubernetes/.secrets.prod`
- D'avoir une base saine avant de basculer en GitOps

### 7.1 Lancer le déploiement

```bash
cd cofrap-stack

# Linux / WSL
./kubernetes/deploy.sh --env prod
```

Ce que ça fait :
1. Vérifie kubectl + helm + accès cluster
2. Skip MetalLB et OpenFaaS (déjà installés aux steps 3 et 5)
3. Génère les secrets (Fernet + 2 mots de passe MariaDB) → `kubernetes/.secrets.prod`
4. `helm upgrade --install cofrap` (release `cofrap` dans ns `cofrap`)
5. `helm upgrade --install cofrap-frontend`
6. Affiche le récap

**Garder le contenu de `kubernetes/.secrets.prod` dans un vault hors-machine** (Bitwarden, 1Password...) — si tu le perds, les données chiffrées en BDD deviennent illisibles.

### 7.2 Vérifier que les pods démarrent

```bash
kubectl get pods -n cofrap
# NAME             READY   STATUS    RESTARTS   AGE
# mariadb-0        1/1     Running   0          90s

kubectl get pods -n openfaas-fn -l 'faas_function'
# NAME                                 READY   STATUS    RESTARTS   AGE
# generate-password-xxxx-yyyy          1/1     Running   0          60s
# generate-2fa-xxxx-yyyy               1/1     Running   0          60s
# authenticate-user-xxxx-yyyy          1/1     Running   0          60s

kubectl get pods -n cofrap -l 'app.kubernetes.io/name=cofrap-frontend'
# cofrap-frontend-xxxx-yyyy            1/1     Running   0          45s
```

Si un pod n'est pas Running → `kubectl describe pod <name> -n cofrap` (events en bas) et `kubectl logs <name> -n cofrap`.

---

## 8. Validation du déploiement Phase 1

### 8.1 Test direct sur le VIP MetalLB

```bash
curl -H 'Host: cofrap.home-maurras.fr' http://192.168.1.241/healthz
# → "ok"  (l'endpoint nginx du frontend)
```

### 8.2 Test depuis Cloudflare Tunnel (Internet)

```bash
curl -I https://cofrap.home-maurras.fr/
# HTTP/2 200
# server: cloudflare
# content-type: text/html
```

**Ouvrir https://cofrap.home-maurras.fr dans un navigateur** — tu dois voir la
SPA Vue 3.

### 8.3 Test d'un appel API (chaîne complète)

```bash
curl -sX POST https://cofrap.home-maurras.fr/api/function/generate-password \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice-prod-test"}' | jq '. | {username, gendate, has_password: (.password != null)}'
# {
#   "username": "alice-prod-test",
#   "gendate": 1748172000,
#   "has_password": true
# }
```

Si ça répond ça : **la stack tourne en prod, end-to-end**. 🎉

### 8.4 Test depuis l'UI

1. Aller sur `https://cofrap.home-maurras.fr`
2. Cliquer « Créer un compte »
3. Saisir un username → tu dois voir un QR + le mot de passe en clair
4. Continuer → générer le 2FA → scanner le QR avec Google Authenticator → saisir le code
5. Tester la connexion sur `/login`

Si ça marche → la Phase 1 est validée.

---

## 9. Installation d'ArgoCD

Maintenant on bascule en Phase 2 (GitOps).

```bash
kubectl create namespace argocd
# IMPORTANT : --server-side évite "Too long: may not be more than 262144 bytes"
# sur la CRD ApplicationSet (~280 KB, dépasse la limite K8s sur les annotations
# côté kubectl apply client-side).
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Attendre que les pods démarrent (~1 min)
kubectl -n argocd wait --for=condition=Ready pod --all --timeout=300s

# Optionnel : on n'utilise pas ApplicationSet dans le setup COFRAP — autant
# libérer le pod et nettoyer les logs.
kubectl -n argocd scale deployment argocd-applicationset-controller --replicas=0
```

### 9.1 Récupérer le mot de passe admin

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
# → garder
```

### 9.2 Accéder à l'UI

Option A — Port-forward (vite, pour valider) :
```bash
kubectl -n argocd port-forward svc/argocd-server 8443:443
# → https://localhost:8443  (user: admin)
```

Option B — Ingress permanent (recommandé) :
```bash
# Exposer ArgoCD via Traefik. Crée un Ingress + un autre hostname Cloudflare Tunnel.
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
    - host: argocd.home-maurras.fr
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

# Et dans Cloudflare Tunnel : ajouter un public hostname `argocd.home-maurras.fr` → `http://192.168.1.241:80`.
```

### 9.3 (Optionnel) Changer le mot de passe admin

Dans l'UI → User Info → Update Password. Ou en CLI après login `argocd account update-password`.

---

## 10. Installation d'ArgoCD Image Updater

C'est le composant clé qui détecte les nouvelles images GHCR et bump les values automatiquement.

### 10.1 Installer Image Updater

```bash
# Le manifest est sous config/install.yaml (PAS manifests/ — ancien chemin = 404)
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/config/install.yaml

# Attendre le pod
kubectl -n argocd rollout status deployment argocd-image-updater-controller-controller --timeout=120s
```

### 10.2 Créer le secret git-creds (avec le PAT du step 6.2)

```bash
# Remplace <PAT> par ton token
kubectl -n argocd create secret generic git-creds \
  --from-literal=username=argocd-image-updater \
  --from-literal=password=<PAT>
```

### 10.3 Appliquer la config Image Updater

```bash
kubectl apply -f kubernetes/argocd/image-updater-config.yaml

# Recharger le pod pour qu'il relise la config
kubectl -n argocd rollout restart deployment argocd-image-updater-controller
```

### 10.4 Vérifier les logs

```bash
kubectl -n argocd logs deploy/argocd-image-updater-controller -f
# Tu dois voir :
# time="..." level=info msg="Starting argocd-image-updater"
# time="..." level=info msg="Loaded 0 image(s) to be considered for update"
#  ^^^ 0 image pour l'instant, car aucune Application n'existe encore. On va corriger au step 13.
```

---

## 11. Préparation des Secrets pour le GitOps

Les Secrets `encryption-key` et `mariadb-password` ne vivent **PAS dans Git**. ArgoCD les ignore (`ignoreDifferences` déjà configuré dans les Applications). On les pré-crée à la main avec les valeurs du cache Phase 1.

### 11.1 Re-créer les secrets cofrap (depuis le cache .secrets.prod)

```bash
# Charger les secrets générés au step 7
source kubernetes/.secrets.prod

# Vérifier qu'ils sont chargés
echo "Fernet  : ${ENCRYPTION_KEY:0:10}..."
echo "MariaDB : ${MARIADB_PASSWORD:0:10}..."

# Les recréer dans openfaas-fn (idempotent)
kubectl create namespace openfaas-fn --dry-run=client -o yaml | kubectl apply -f -

kubectl -n openfaas-fn create secret generic encryption-key \
  --from-literal=encryption-key="$ENCRYPTION_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n openfaas-fn create secret generic mariadb-password \
  --from-literal=mariadb-password="$MARIADB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
```

> Note : ces Secrets existent déjà depuis le step 7 (créés par le chart Helm). Cette
> commande les recrée à l'identique pour que tu saches exactement ce qui est dedans.
> ArgoCD les ignorera (`ignoreDifferences` sur leurs `data`).

---

## 12. Connexion ArgoCD au repo cofrap-stack

ArgoCD doit pouvoir **lire ET écrire** dans cofrap-stack (Image Updater commit des bumps).

### 12.1 Via l'UI ArgoCD

1. **Settings → Repositories → CONNECT REPO**
2. Method : **HTTPS**
3. Type : Git
4. Project : default
5. Repository URL : `https://github.com/COFRAP-EPSI-2026/cofrap-stack.git`
6. Username : `argocd-image-updater`
7. Password : **le même PAT que step 10.2**
8. ✅ **Enable submodules** ← TRÈS IMPORTANT (sinon `backend/` et `frontend/` ne sont pas téléchargés)
9. **CONNECT**

Tu dois voir `Connection Status: Successful`.

### 12.2 Via CLI (alternative)

```bash
# Si tu as installé l'argocd CLI
argocd login <argocd-host> --username admin --password <pwd>

argocd repo add https://github.com/COFRAP-EPSI-2026/cofrap-stack.git \
  --username argocd-image-updater \
  --password <PAT> \
  --enable-submodule

argocd repo list
# REPO                                                            INSECURE   USER                     ...
# https://github.com/COFRAP-EPSI-2026/cofrap-stack.git            false      argocd-image-updater     ...
```

---

## 13. Bootstrap GitOps (App-of-Apps)

C'est le **moment magique**. Une seule commande, et ArgoCD prend le relais.

### 13.1 (Important) Supprimer les releases Helm Phase 1

Sinon ArgoCD va vouloir adopter des Helm releases qui existent déjà — ça marche mais ça déclenche des `OutOfSync` parasites au début.

```bash
helm uninstall cofrap          -n cofrap
helm uninstall cofrap-frontend -n cofrap

# Les pods disparaissent — ça va revenir en 1 min au step 13.2.
# ⚠ Les PVC MariaDB et les Secrets, eux, restent (les Helm releases les ont créés
#    avec keep policy). C'est PARFAIT — ArgoCD va re-créer les Deployments
#    par-dessus, et MariaDB retrouve ses données chiffrées.
```

Vérifier que les PVC et Secrets sont toujours là :
```bash
kubectl get pvc -n cofrap
kubectl get secret -n openfaas-fn
```

### 13.2 Appliquer l'App-of-Apps prod

```bash
kubectl apply -f kubernetes/argocd/app-of-apps.prod.yaml
```

### 13.3 Suivre la création des Applications

```bash
# Watch dans le terminal
kubectl -n argocd get applications -w

# Ou dans l'UI ArgoCD : 3 cartes apparaissent
#   - cofrap-stack-prod      (la racine)
#   - cofrap-backend-prod
#   - cofrap-frontend-prod
```

ArgoCD va automatiquement (~1-2 min) :
1. Voir l'App-of-Apps `cofrap-stack-prod`
2. Créer les 2 Applications enfants (`cofrap-backend-prod`, `cofrap-frontend-prod`)
3. Pour chacune : `git clone` du repo (avec submodules) → `helm template` → `kubectl apply`
4. Les pods reviennent en Running

### 13.4 Vérifier que tout est `Synced / Healthy`

```bash
kubectl -n argocd get applications
# NAME                    SYNC STATUS   HEALTH STATUS
# cofrap-stack-prod       Synced        Healthy
# cofrap-backend-prod     Synced        Healthy
# cofrap-frontend-prod    Synced        Healthy
```

Si une App reste `OutOfSync` → cliquer dessus dans l'UI → onglet `DIFF` pour voir
ce qui cloche, puis `SYNC` manuel pour forcer.

### 13.5 Re-tester la stack (toujours OK ?)

```bash
curl -I https://cofrap.home-maurras.fr/
# HTTP/2 200
```

À ce stade, **tu es en GitOps complet**. Tout changement git push → ArgoCD reconcile.

---

## 14. Test bout-en-bout du flow auto

### 14.1 Vérifier que Image Updater voit les Applications

```bash
kubectl -n argocd logs deploy/argocd-image-updater-controller | tail -20
# Tu dois voir :
# time="..." level=info msg="Loaded 2 image(s) to be considered for update"
# time="..." level=info msg="Processing image list for application cofrap-backend-prod"
# time="..." level=info msg="Processing image list for application cofrap-frontend-prod"
```

### 14.2 Test artificiel : tagger une release manuellement

> Pour ne pas attendre la prochaine vraie release, on simule en repushant un tag existant
> ou en bumpant le tag dans cofrap-stack et en voyant ArgoCD réagir.

```bash
# Modifier le tag manuellement dans cofrap-stack
cd cofrap-stack
sed -i 's/^  version: .*/  version: "v2026.3.2"/' kubernetes/values/backend.prod.yaml
git commit -am "chore: test bump backend → v2026.3.2"
git push

# Dans 1-3 min, dans l'UI ArgoCD :
# - cofrap-backend-prod passe en OutOfSync
# - SelfHeal=false en prod → tu dois cliquer SYNC manuellement (ou attendre l'auto-sync)
# - Les 3 fonctions sont redéployées sur v2026.3.2
```

### 14.3 Test vrai bout-en-bout (sur une vraie release)

Sur le repo `cofrap-backend` :

```bash
# Sur ta machine de dev, branche main
git commit -am "fix: bump test pour valider le GitOps"
git push origin main
# → Release Please ouvre une PR
# → Tu la merges
# → Release Please crée le tag v2026.X.Y+1
# → release-please.yml build & push les 3 images sur GHCR
# → (attendre ~5 min)
# → Image Updater détecte → commit dans cofrap-stack
# → (attendre ~30s)
# → ArgoCD reconcile → kubectl rollout
# → Prod live sur la nouvelle version
```

Surveiller en parallèle :
```bash
# Logs Image Updater (sur le cluster)
kubectl -n argocd logs deploy/argocd-image-updater-controller -f

# Commits arrivant sur cofrap-stack
watch -n 30 'git -C ~/cofrap-stack log -3 --oneline'

# Pods qui se rollent
kubectl get pods -n openfaas-fn -w
```

Si tu vois la séquence complète, **félicitations, tu es en GitOps 100% automatique**. 🎉

---

## 15. Opérations courantes en prod

### 15.1 Voir l'état général

```bash
# Cluster
kubectl get nodes
kubectl top nodes                         # CPU/mémoire

# Stack COFRAP
kubectl get pods -n cofrap
kubectl get pods -n openfaas-fn -l 'faas_function'
kubectl top pods -A --sort-by=memory      # qui consomme

# ArgoCD
kubectl -n argocd get applications
```

### 15.2 Voir les logs d'une fonction

```bash
kubectl logs -l 'faas_function=generate-password' -n openfaas-fn --tail=100 -f
```

### 15.3 Backup MariaDB (recommandé : cron quotidien)

```bash
# Manuel ad-hoc
kubectl exec -n cofrap mariadb-0 -- \
  mariadb-dump -uroot -p"$(kubectl get secret mariadb-credentials -n cofrap -o jsonpath='{.data.MARIADB_ROOT_PASSWORD}' | base64 -d)" --all-databases \
  > backup-cofrap-$(date +%F).sql

# Cron quotidien à 3h du matin
crontab -e
# Ajouter :
# 0 3 * * * /home/<user>/scripts/backup-cofrap.sh
```

Bonus : copier le dump vers un stockage hors-cluster (S3, Nextcloud, autre serveur).

### 15.4 Rotation de la clé Fernet (cas grave, perte de clé suspectée)

> Compliqué : il faut déchiffrer avec l'ancienne, ré-encrypter avec la nouvelle, ré-écrire en BDD.
> Cf. [`backend/docs/fr/security.md`](../backend/docs/fr/security.md). Procédure manuelle uniquement.

### 15.5 Bump manuel d'image (sans attendre Image Updater)

Si tu veux pousser une version en prod **immédiatement** :

```bash
cd cofrap-stack
sed -i 's/^  version: .*/  version: "v2026.X.Y"/' kubernetes/values/backend.prod.yaml
# ou pour le frontend :
sed -i 's/^  tag: .*/  tag: "v2026.X.Y"/' kubernetes/values/frontend.prod.yaml

git commit -am "chore: bump <comp> to v2026.X.Y"
git push

# Force la sync immédiate (sinon ArgoCD attend son polling de 3 min)
argocd app sync cofrap-backend-prod
# ou
kubectl -n argocd annotate app cofrap-backend-prod argocd.argoproj.io/refresh=hard --overwrite
```

### 15.6 Bump manuel d'un chart Helm (rare, si tu modifies les templates)

Si quelqu'un modifie `backend/deploy/helm/cofrap/templates/...` dans cofrap-backend, ArgoCD ne voit rien (submodule figé). Il faut bumper le pointeur :

```bash
cd cofrap-stack
git submodule update --remote backend
git add backend
git commit -m "chore: bump backend submodule to include <changement>"
git push
# ArgoCD voit le commit → reconcile → applique le nouveau template
```

---

## 16. Recovery / Disaster

### 16.1 Rollback d'une release qui plante

```bash
# Via ArgoCD UI : sur l'Application → onglet HISTORY → choisir une révision précédente → ROLLBACK
# Via CLI :
argocd app history cofrap-backend-prod
argocd app rollback cofrap-backend-prod <revision-id>

# Via Helm direct (bypass ArgoCD — d'urgence seulement)
helm history cofrap -n cofrap
helm rollback cofrap <revision> -n cofrap
# ⚠ ArgoCD va vouloir re-converger vers Git ; bloque-le temporairement (suspendre l'auto-sync)
#   le temps de fixer le Git puis re-laisser ArgoCD bosser.
```

### 16.2 Restaurer MariaDB depuis un backup

```bash
# Copier le dump dans le pod
kubectl cp backup-cofrap-2026-05-25.sql cofrap/mariadb-0:/tmp/backup.sql

# Restaurer (⚠ DROP des données actuelles)
kubectl exec -n cofrap mariadb-0 -- \
  bash -c "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" < /tmp/backup.sql"
```

### 16.3 Re-déployer toute la stack from scratch (en gardant les données)

```bash
# Désinstaller (ArgoCD garde les PVC MariaDB et les Secrets)
kubectl -n argocd delete application cofrap-stack-prod   # supprime l'App-of-Apps en cascade

# Vérifier que MariaDB PVC + Secrets sont toujours là
kubectl get pvc -n cofrap
kubectl get secret -n openfaas-fn

# Redéployer (en GitOps direct)
kubectl apply -f kubernetes/argocd/app-of-apps.prod.yaml
# → 1-2 min plus tard, la stack revient sur les mêmes données
```

### 16.4 Reconstruire le cluster complet (perte serveur)

1. Réinstaller K3s (step 2)
2. Réinstaller MetalLB (step 3)
3. Cloudflare Tunnel : pointer sur le nouveau VIP si IP a changé
4. Réinstaller OpenFaaS (step 5)
5. **Restaurer le fichier `kubernetes/.secrets.prod` depuis ton vault** (Bitwarden, etc.)
6. `./kubernetes/deploy.sh --env prod` (Phase 1)
7. **Restaurer le dump MariaDB** (§ 16.2)
8. Réinstaller ArgoCD + Image Updater (steps 9, 10)
9. Bootstrap GitOps (step 13)

Compter ~30 min si tu as les backups + le `.secrets.prod` à portée de main.

### 16.5 Cluster Down (post-mortem)

```bash
# K3s ne démarre plus ?
sudo journalctl -u k3s -n 200 --no-pager

# Disque plein ?
df -h
docker system df       # si Docker installé
sudo crictl stats      # containers en cours

# OOMKilled fréquents ?
kubectl get events -A --sort-by=.lastTimestamp | grep OOM
```

---

## Aller plus loin

- 📋 [`cheatsheet.md`](cheatsheet.md) — toutes les commandes contextualisées (kubectl, helm, k3s, argocd, image updater...)
- 🏗️ [`kubernetes/README.md`](../kubernetes/README.md) — pourquoi cette architecture, choix techniques
- 🤖 [`kubernetes/argocd/README.md`](../kubernetes/argocd/README.md) — détails Phase 2 (App-of-Apps, Image Updater, secrets)
- 🔒 [`backend/docs/fr/security.md`](../backend/docs/fr/security.md) — modèle de menace, rate-limit, rotation de clés
- 🌐 [Documentation Cloudflare Zero Trust](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
