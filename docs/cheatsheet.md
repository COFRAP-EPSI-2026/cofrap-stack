# Cheatsheet — déploiement et opération de la stack COFRAP

Aide-mémoire des commandes courantes pour **exploiter la stack COFRAP** sur
Kubernetes. Toutes les commandes sont contextualisées au projet (namespaces,
releases, IP) — adapte si tu déploies différemment.

> Pour le déploiement « clés en main », voir [`kubernetes/README.md`](../kubernetes/README.md).
> Cette page sert quand tu veux **faire quelque chose à la main** : debug,
> inspection, opération ponctuelle.

## Sommaire

- [Conventions du projet COFRAP](#conventions-du-projet-cofrap)
- [Pré-requis & installation des outils](#pré-requis--installation-des-outils)
- [`kubectl` — l'essentiel](#kubectl--lessentiel)
- [Helm](#helm)
- [K3s](#k3s)
- [Minikube](#minikube)
- [MetalLB](#metallb)
- [OpenFaaS](#openfaas)
- [ArgoCD](#argocd)
- [ArgoCD Image Updater](#argocd-image-updater)
- [Stack COFRAP — commandes spécifiques](#stack-cofrap--commandes-spécifiques)
- [Debug courant](#debug-courant)
- [Recettes complètes](#recettes-complètes)

---

## Conventions du projet COFRAP

| Élément              | Valeur dev                   | Valeur prod                |
|----------------------|------------------------------|----------------------------|
| Namespace stack      | `cofrap-dev`                 | `cofrap`                   |
| Namespace OpenFaaS   | `openfaas`                   | `openfaas`                 |
| Namespace fonctions  | `openfaas-fn`                | `openfaas-fn`              |
| Release backend      | `cofrap-dev`                 | `cofrap`                   |
| Release frontend     | `cofrap-frontend-dev`        | `cofrap-frontend`          |
| IP MetalLB (VIP)     | `192.168.1.240`              | `192.168.1.241`            |
| Hostname public      | `cofrap-dev.home-maurras.fr` | `cofrap.home-maurras.fr`   |
| Tag image backend    | `dev`                        | `latest` / `v2026.X.Y`     |
| Tag image frontend   | `dev`                        | `latest` / `v2026.X.Y`     |

Dans la suite, le placeholder `<env>` vaut `dev` ou `prod`. Le namespace `<ns>` correspond.

---

## Pré-requis & installation des outils

### Linux / WSL / macOS

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# k9s (TUI K8s — fortement recommandé pour le debug)
curl -sS https://webinstall.dev/k9s | bash

# argocd CLI (optionnel — l'UI suffit souvent)
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd /usr/local/bin/argocd
```

### Windows (PowerShell, via winget)

```powershell
winget install -e --id Kubernetes.kubectl
winget install -e --id Helm.Helm
winget install -e --id Derailed.k9s
winget install -e --id ArgoProj.argocd-cli
```

### Vérifier que tout est OK

```bash
kubectl version --client
helm version --short
k9s version
kubectl cluster-info        # doit lister le master + DNS
kubectl get nodes -o wide   # doit lister tes nodes Ready
```

---

## `kubectl` — l'essentiel

### Contexte & config

```bash
# Lister les contextes (multi-cluster)
kubectl config get-contexts

# Changer de cluster (utile entre dev et prod)
kubectl config use-context <ton-cluster-dev>

# Voir le contexte actif et le namespace par défaut
kubectl config current-context
kubectl config view --minify

# Fixer un namespace par défaut pour ce contexte (évite de retaper -n)
kubectl config set-context --current --namespace=cofrap-dev
```

### Lister des ressources

```bash
# Pods d'un namespace
kubectl get pods -n cofrap-dev
kubectl get pods -n cofrap-dev -o wide                # + IP, node, ...
kubectl get pods -A                                   # tous les namespaces

# Watch en live (rafraîchit chaque ligne — Ctrl+C pour quitter)
kubectl get pods -n cofrap-dev -w

# Lister TOUT dans un namespace
kubectl get all -n cofrap-dev

# Filtrer par label (le label des fonctions OpenFaaS COFRAP)
kubectl get pods -n openfaas-fn -l 'faas_function'

# Sortie YAML / JSON
kubectl get pod <pod-name> -n cofrap-dev -o yaml
kubectl get pod <pod-name> -n cofrap-dev -o jsonpath='{.status.phase}'
```

### Décrire / inspecter

```bash
# Description complète (events à la fin — très utile pour debug)
kubectl describe pod <pod-name> -n cofrap-dev

# Events d'un namespace, triés par horodatage
kubectl get events -n cofrap-dev --sort-by=.lastTimestamp

# Voir les noms des Secrets / ConfigMap
kubectl get secret -n openfaas-fn
kubectl get configmap -n cofrap-dev

# Décoder un secret (les data sont en base64)
kubectl get secret mariadb-password -n openfaas-fn \
  -o jsonpath='{.data.mariadb-password}' | base64 -d ; echo
```

### Logs

```bash
kubectl logs <pod> -n cofrap-dev                      # logs simples
kubectl logs <pod> -n cofrap-dev -f                   # follow (tail -f)
kubectl logs <pod> -n cofrap-dev --tail=200           # dernières 200 lignes
kubectl logs <pod> -n cofrap-dev --previous           # après un crash : logs de l'instance précédente
kubectl logs -l 'faas_function=generate-password' -n openfaas-fn -f   # par label
kubectl logs deploy/generate-password -n openfaas-fn -f               # par Deployment
```

### Exec dans un pod

```bash
# Shell interactif
kubectl exec -it <pod> -n cofrap-dev -- /bin/sh
kubectl exec -it deploy/generate-password -n openfaas-fn -- /bin/sh

# Commande one-shot (sans -it pour les commandes non-interactives)
kubectl exec mariadb-0 -n cofrap-dev -- mariadb -ucofrap -p"$PWD" cofrap -e "SHOW TABLES"
```

### Port-forward (accès local à un Service interne)

```bash
# Gateway OpenFaaS sur localhost:8080
kubectl port-forward -n openfaas svc/gateway 8080:8080

# MariaDB sur localhost:3306 (pour brancher DBeaver / DataGrip)
kubectl port-forward -n cofrap-dev svc/mariadb 3306:3306

# Frontend cofrap-frontend sur localhost:8080 (sans Ingress)
kubectl port-forward -n cofrap-dev svc/cofrap-frontend-dev 8080:80
```

### Apply / delete / rollout

```bash
# Appliquer / mettre à jour des manifestes
kubectl apply -f manifest.yaml
kubectl apply -f kubernetes/loadbalancing/metallb-pool.dev.yaml
kubectl apply -f https://exemple.com/install.yaml

# Supprimer
kubectl delete -f manifest.yaml
kubectl delete pod <pod> -n cofrap-dev                # supprime → Deployment recrée
kubectl delete namespace cofrap-dev                   # ⚠ supprime TOUT le namespace

# Redémarrer un Deployment (sans toucher au YAML)
kubectl rollout restart deployment/generate-password -n openfaas-fn
kubectl rollout restart deployment -l 'faas_function' -n openfaas-fn   # toutes les fonctions

# Suivre l'avancement d'un rollout
kubectl rollout status deployment/generate-password -n openfaas-fn

# Historique + rollback
kubectl rollout history deployment/generate-password -n openfaas-fn
kubectl rollout undo deployment/generate-password -n openfaas-fn       # revert au précédent
```

### Edit en live (à utiliser pour debug rapide, jamais en prod)

```bash
kubectl edit deployment/generate-password -n openfaas-fn   # ouvre $EDITOR
```

### Scaling

```bash
kubectl scale deployment/generate-password --replicas=3 -n openfaas-fn
kubectl scale deployment -l 'faas_function' --replicas=2 -n openfaas-fn
```

### Ressources & métriques (nécessite metrics-server)

```bash
kubectl top nodes
kubectl top pods -n cofrap-dev
kubectl top pods -A --sort-by=memory
```

---

## Helm

### Setup repos

```bash
helm repo add openfaas         https://openfaas.github.io/faas-netes/
helm repo add bitnami          https://charts.bitnami.com/bitnami
helm repo add sealed-secrets   https://bitnami-labs.github.io/sealed-secrets
helm repo add argo             https://argoproj.github.io/argo-helm
helm repo add traefik          https://traefik.github.io/charts
helm repo update
```

### Install / upgrade / uninstall

```bash
# Install : crée la release ou échoue si elle existe
helm install <release> <chart> -n <ns> --create-namespace

# Upgrade : modifie une release existante, install si elle n'existe pas
helm upgrade --install <release> <chart> -n <ns>

# Upgrade COFRAP backend (la commande qu'utilise deploy.sh)
helm upgrade --install cofrap-dev ./backend/deploy/helm/cofrap \
  --namespace cofrap-dev --create-namespace \
  --values kubernetes/values/backend.dev.yaml \
  --set secrets.encryptionKey=... \
  --wait --timeout 10m

# Désinstaller
helm uninstall cofrap-dev -n cofrap-dev
```

### Inspecter une release

```bash
helm list -A                                          # toutes les releases du cluster
helm list -n cofrap-dev
helm status cofrap-dev -n cofrap-dev                  # état (NOTES.txt inclus)
helm get values cofrap-dev -n cofrap-dev              # valeurs custom appliquées
helm get values cofrap-dev -n cofrap-dev -a           # valeurs custom + defaults du chart
helm get manifest cofrap-dev -n cofrap-dev            # YAML K8s effectif déployé
```

### Historique & rollback

```bash
helm history cofrap-dev -n cofrap-dev                 # versions précédentes
helm rollback cofrap-dev 2 -n cofrap-dev              # revenir à la révision 2
```

### Valider un chart sans toucher au cluster

```bash
# Lint (syntaxe, valeurs requises)
helm lint backend/deploy/helm/cofrap

# Voir le YAML K8s qui serait appliqué
helm template cofrap backend/deploy/helm/cofrap \
  --set secrets.encryptionKey=dummy \
  --set secrets.mariadbPassword=dummy \
  --set secrets.mariadbRootPassword=dummy

# Dry-run + diff vs. le cluster (nécessite le plugin helm-diff)
helm plugin install https://github.com/databus23/helm-diff
helm diff upgrade cofrap-dev ./backend/deploy/helm/cofrap -n cofrap-dev \
  -f kubernetes/values/backend.dev.yaml
```

### Forcer le pull d'une image mobile (`:dev`, `:latest`)

```bash
# Helm ne détecte PAS qu'une image mobile a un nouveau digest. Force le rollout :
kubectl rollout restart deployment -l 'faas_function' -n openfaas-fn
kubectl rollout restart deployment cofrap-frontend-dev -n cofrap-dev
```

---

## K3s

K3s = Kubernetes léger pour homelab. Une seule binaire, install en 10 secondes.

### Installation

```bash
# Server (master) avec un seul node : suffit pour le PoC COFRAP
curl -sfL https://get.k3s.io | sh -

# Personnaliser : désactiver ServiceLB (on utilise MetalLB) + traefik conservé
sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<'EOF'
disable:
  - servicelb
EOF
sudo systemctl restart k3s

# Worker node — récupérer le token sur le master :
sudo cat /var/lib/rancher/k3s/server/node-token   # sur le master
# puis sur le worker :
curl -sfL https://get.k3s.io | K3S_URL=https://<master-ip>:6443 K3S_TOKEN=<token> sh -
```

### Récupérer le kubeconfig

```bash
# Sur le master, le kubeconfig est dans /etc/rancher/k3s/k3s.yaml
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config

# Pour s'y connecter depuis un autre poste : remplacer 127.0.0.1 par l'IP du master
sed -i "s/127.0.0.1/<ip-master>/" ~/.kube/config
```

### Opérations courantes

```bash
# État du service K3s
sudo systemctl status k3s

# Logs K3s
sudo journalctl -u k3s -f

# Voir les manifests appliqués automatiquement (traefik, coredns, etc.)
ls /var/lib/rancher/k3s/server/manifests/

# Désinstaller K3s (server)
/usr/local/bin/k3s-uninstall.sh

# Désinstaller K3s (worker)
/usr/local/bin/k3s-agent-uninstall.sh
```

### Images Docker → cluster K3s (sans registre)

```bash
# Build l'image localement, puis l'importer dans K3s :
docker build -t cofrap-frontend:dev .
docker save cofrap-frontend:dev | sudo k3s ctr images import -

# Vérifier
sudo k3s ctr images list | grep cofrap

# Côté chart : passer pullPolicy: IfNotPresent
helm upgrade cofrap-frontend ./deploy/helm/cofrap-frontend --reuse-values \
  --set image.pullPolicy=IfNotPresent
```

---

## Minikube

Minikube = cluster mono-node pour dev local. Plus lourd que K3s mais multi-OS.

### Installation

```bash
# Linux
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# Windows
winget install -e --id Kubernetes.minikube

# macOS
brew install minikube
```

### Démarrer / arrêter

```bash
minikube start --cpus=2 --memory=4096 --disk-size=20g
minikube start --driver=docker            # forcer Docker (Linux/macOS)
minikube start --driver=hyperv            # Windows + Hyper-V
minikube start --driver=virtualbox        # fallback

minikube status                            # état du cluster
minikube stop                              # arrêter (garde l'état)
minikube delete                            # détruire complètement
```

### Addons utiles

```bash
minikube addons list                       # tous les addons disponibles
minikube addons enable ingress             # NGINX ingress controller
minikube addons enable metallb             # alternative à MetalLB manuel
minikube addons enable metrics-server      # pour kubectl top
```

### Exposer un Service LoadBalancer (équivalent MetalLB)

```bash
# Sans ce tunnel, les Services type LoadBalancer restent en <pending>
minikube tunnel                            # laisser tourner (CTRL+C pour arrêter)
```

### Images locales → cluster Minikube

```bash
# Option A : utiliser le daemon Docker DU minikube (build directement dedans)
eval $(minikube docker-env)                # bash/zsh
& minikube -p minikube docker-env --shell powershell | Invoke-Expression   # PowerShell
docker build -t cofrap-frontend:dev .      # ce build est visible par minikube
# Pour revenir au Docker normal : eval $(minikube docker-env -u)

# Option B : importer une image déjà construite
minikube image load cofrap-frontend:dev

# Lister les images dans le cluster
minikube image ls
```

### Accès rapide

```bash
minikube dashboard                         # ouvre la dashboard K8s dans un browser
minikube service <svc> -n <ns>             # ouvre un Service dans le browser
minikube ip                                # IP du node minikube
minikube ssh                               # shell dans la VM minikube
```

---

## MetalLB

MetalLB = LoadBalancer software pour clusters bare-metal (homelab). Donne une **IP virtuelle stable** à un Service `type: LoadBalancer`.

### Installation (manifeste natif — déjà fait pour COFRAP)

```bash
# Manifeste officiel (évite le chart Helm qui a un bug frr-k8s)
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

# Attendre que tout soit Ready
kubectl -n metallb-system wait --for=condition=Ready pod --all --timeout=120s
```

### Pool d'IPs + L2Advertisement

```bash
# Appliquer le pool de l'env COFRAP (192.168.1.240 en dev, .241 en prod)
kubectl apply -f kubernetes/loadbalancing/metallb-pool.dev.yaml
```

### Debug

```bash
# Voir les pods MetalLB
kubectl get pods -n metallb-system

# Vérifier que le Service traefik (K3s) a bien pris l'IP du pool
kubectl get svc -A | grep LoadBalancer
# kube-system   traefik   LoadBalancer   10.43.x.y   192.168.1.240   80:30000/TCP

# Voir les logs du speaker (le composant L2)
kubectl logs -n metallb-system -l 'app=metallb,component=speaker' -f

# Voir les pools configurés
kubectl get ipaddresspools -n metallb-system
kubectl get l2advertisements -n metallb-system
```

### Tests fonctionnels

```bash
# Depuis un autre poste du LAN, ping/curl sur l'IP attribuée :
ping 192.168.1.240
curl -H 'Host: cofrap-dev.home-maurras.fr' http://192.168.1.240/
```

---

## OpenFaaS

### Installation Community

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

# ⚠ ne JAMAIS passer `--set operator.create=true` en Community
# (l'operator est réservé à OpenFaaS Pro).
```

### Récupérer le mot de passe admin

```bash
kubectl -n openfaas get secret basic-auth \
  -o jsonpath='{.data.basic-auth-password}' | base64 -d ; echo
```

### `faas-cli` — utiliser le gateway

```bash
# Install
curl -sSfL https://cli.openfaas.com | sudo sh

# Port-forward + login (laisser le port-forward tourner)
kubectl port-forward -n openfaas svc/gateway 8080:8080 &
echo "$PASSWORD" | faas-cli login -u admin --password-stdin

# Lister les fonctions visibles par le gateway
faas-cli list

# Invoquer une fonction COFRAP
echo '{"username":"alice"}' | faas-cli invoke generate-password

# Logs d'une fonction
faas-cli logs generate-password

# Lister les secrets OpenFaaS (montés dans /var/openfaas/secrets/<name>)
faas-cli secret list

# Créer un secret OpenFaaS à la main
echo -n 'ma-cle-fernet' | faas-cli secret create encryption-key --from-literal -
```

### Découverte des fonctions (sans operator)

OpenFaaS Community découvre les fonctions via le **label `faas_function=<name>`** sur les Deployments + Services dans `openfaas-fn` :

```bash
# Vérifier que les 3 fonctions COFRAP sont vues
kubectl -n openfaas-fn get deploy,svc -l 'faas_function'

# Forcer une re-découverte (rare)
kubectl rollout restart deployment -l 'app=gateway' -n openfaas
```

### Désinstaller OpenFaaS

```bash
helm uninstall openfaas -n openfaas
kubectl delete namespace openfaas openfaas-fn --wait=false
```

---

## ArgoCD

### Installation

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
```

### UI

```bash
# Port-forward de l'UI
kubectl -n argocd port-forward svc/argocd-server 8443:443
# → https://localhost:8443  (user: admin)
```

### CLI

```bash
# Login (depuis le port-forward)
argocd login localhost:8443 --insecure --username admin --password <pwd>

# Lister les Applications
argocd app list
argocd app get cofrap-backend-prod

# Forcer une sync manuelle
argocd app sync cofrap-backend-prod
argocd app sync cofrap-backend-prod --prune
argocd app sync cofrap-backend-prod --force         # ignore les diffs

# Voir le diff entre Git et le cluster
argocd app diff cofrap-backend-prod

# Historique de déploiements
argocd app history cofrap-backend-prod
argocd app rollback cofrap-backend-prod <revision>
```

### Repos & credentials

```bash
# Ajouter le repo cofrap-stack avec un PAT (pour Image Updater write-back)
argocd repo add https://github.com/COFRAP-EPSI-2026/cofrap-stack.git \
  --username argocd-image-updater \
  --password <PAT> \
  --enable-submodule

# Lister les repos connus
argocd repo list
```

### Bootstrap COFRAP

```bash
# Une seule commande après création du PAT + install ArgoCD
kubectl apply -f kubernetes/argocd/app-of-apps.dev.yaml
# (ou app-of-apps.prod.yaml)
```

### Voir l'état d'une Application

```bash
kubectl -n argocd get application                           # via kubectl
kubectl -n argocd get application cofrap-backend-dev -o yaml
```

### Désinstaller ArgoCD

```bash
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl delete namespace argocd
```

---

## ArgoCD Image Updater

### Installation

```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml
```

### Configuration

```bash
# Secret git-creds (PAT GitHub avec scope `repo` sur cofrap-stack)
kubectl -n argocd create secret generic git-creds \
  --from-literal=username=argocd-image-updater \
  --from-literal=password=<PAT>

# ConfigMap (registre + identité du committer)
kubectl apply -f kubernetes/argocd/image-updater-config.yaml

# Recharger le pod
kubectl -n argocd rollout restart deployment argocd-image-updater
```

### Logs & debug

```bash
# Logs en live — Image Updater polle toutes les 2 min
kubectl -n argocd logs deploy/argocd-image-updater -f

# Vérifier qu'il voit les images du registre
kubectl -n argocd exec deploy/argocd-image-updater -- \
  argocd-image-updater test ghcr.io/cofrap-epsi-2026/cofrap-frontend

# Forcer un cycle (pas vraiment nécessaire, mais utile en debug)
kubectl -n argocd rollout restart deployment argocd-image-updater
```

### Vérifier qu'un bump est passé

```bash
# Côté cluster : voir la nouvelle valeur dans la release Helm
helm get values cofrap-frontend -n cofrap | grep -A 2 image

# Côté Git : voir le commit auto
cd cofrap-stack
git log --oneline kubernetes/values/frontend.prod.yaml
git show HEAD                              # le bump le plus récent
```

---

## Stack COFRAP — commandes spécifiques

### Vérifier les pods de la stack après déploiement

```bash
# MariaDB + ressources stack
kubectl get all,pvc -n cofrap-dev

# Les 3 fonctions OpenFaaS
kubectl get deploy,svc,pods -n openfaas-fn -l 'faas_function'

# Tout d'un coup
kubectl get pods -n cofrap-dev,openfaas-fn,openfaas
```

### Healthchecks individuels

```bash
# Depuis un port-forward du gateway :
kubectl port-forward -n openfaas svc/gateway 8080:8080 &

curl -s http://127.0.0.1:8080/function/generate-password/healthz
curl -s http://127.0.0.1:8080/function/generate-2fa/healthz
curl -s http://127.0.0.1:8080/function/authenticate-user/healthz

# Tester un appel POST
curl -sX POST http://127.0.0.1:8080/function/generate-password \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice"}' | jq
```

### Lire le mot de passe MariaDB depuis le Secret

```bash
kubectl get secret mariadb-credentials -n cofrap-dev \
  -o jsonpath='{.data.MARIADB_PASSWORD}' | base64 -d ; echo
```

### Se connecter à la BDD COFRAP

```bash
# Soit en exec direct dans le pod MariaDB :
kubectl exec -it -n cofrap-dev mariadb-0 -- \
  mariadb -ucofrap -p"$(kubectl get secret mariadb-credentials -n cofrap-dev -o jsonpath='{.data.MARIADB_PASSWORD}' | base64 -d)" cofrap

# Soit en port-forward + client local
kubectl port-forward -n cofrap-dev svc/mariadb 3306:3306
mariadb -h 127.0.0.1 -ucofrap -p<password> cofrap
```

### Lire le contenu chiffré (debug)

```sql
USE cofrap;
SELECT id, username, gendate, expired,
       LENGTH(password) AS pwd_len,
       LENGTH(mfa)      AS mfa_len
  FROM users;
```

### Rejouer le déploiement sans regénérer les secrets

```bash
# Le cache .secrets.<env> est conservé entre les runs — re-exécution safe
./kubernetes/deploy.sh --env dev

# Pour vraiment regénérer (⚠ perd les données chiffrées)
rm kubernetes/.secrets.dev
./kubernetes/deploy.sh --env dev
```

---

## Debug courant

### Pod stuck `Pending` / `ImagePullBackOff` / `CrashLoopBackOff`

```bash
# 1. Voir l'événement qui explique
kubectl describe pod <pod> -n <ns>
# → cherche la section "Events:" en bas

# 2. Vérifier l'image (mauvais tag, repo privé sans pull secret...)
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.containers[*].image}'

# 3. Pour CrashLoopBackOff : voir les logs du dernier crash
kubectl logs <pod> -n <ns> --previous

# 4. Pour Pending : storageclass manquante ? Pas de nodes assez gros ?
kubectl get pvc -n <ns>
kubectl describe pvc <pvc> -n <ns>
kubectl get storageclass
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
```

### Service répond en 502 / timeout

```bash
# Le pod est-il vraiment Ready ?
kubectl get pods -n <ns> -o wide

# Le Service a-t-il des Endpoints ?
kubectl get endpoints -n <ns>                # si vide : selector du Service ne match aucun pod

# Vérifier le selector
kubectl get svc <svc> -n <ns> -o yaml | grep -A 5 selector
kubectl get pods -n <ns> --show-labels
```

### Ingress ne route pas

```bash
# L'Ingress a-t-il une ADDRESS ?
kubectl get ingress -n cofrap-dev

# Si pas d'adresse : pas d'ingress controller, ou className incorrect
kubectl get ingressclass
kubectl describe ingress <name> -n cofrap-dev

# Test direct sans DNS (force le Host)
curl -H 'Host: cofrap-dev.home-maurras.fr' http://192.168.1.240/healthz
```

### DNS interne cluster ne résout pas

```bash
# Lancer un pod debug temporaire
kubectl run -n cofrap-dev debug --rm -it --image=busybox -- sh
# Dans le pod :
nslookup mariadb.cofrap-dev.svc.cluster.local
nslookup gateway.openfaas.svc.cluster.local

# Vérifier CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
```

### Voir TOUT ce qui bouge dans le cluster (firehose)

```bash
# Les events de tout le cluster, triés
kubectl get events -A --sort-by=.lastTimestamp | tail -50

# Ou avec k9s (UI TUI — la meilleure expérience)
k9s
# → puis taper `:events` ou `:po` pour les pods, etc.
```

### Cleanup de ressources orphelines

```bash
# Pods en Error / Completed à supprimer
kubectl delete pod --field-selector=status.phase=Failed -A
kubectl delete pod --field-selector=status.phase=Succeeded -A

# Tous les pods d'un namespace (utile après un test foireux)
kubectl delete pods --all -n cofrap-dev

# Forcer la suppression d'un namespace bloqué en `Terminating`
kubectl get namespace cofrap-dev -o json \
  | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/cofrap-dev/finalize" -f -
```

---

## Recettes complètes

### Recette 1 — Premier déploiement COFRAP sur un nouveau cluster K3s

```bash
# 1. Installer K3s (server)
curl -sfL https://get.k3s.io | sh -

# 2. Désactiver ServiceLB (pour MetalLB)
sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<'EOF'
disable:
  - servicelb
EOF
sudo systemctl restart k3s

# 3. Récupérer le kubeconfig
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config

# 4. Cloner cofrap-stack + récupérer les submodules
git clone https://github.com/COFRAP-EPSI-2026/cofrap-stack.git
cd cofrap-stack
bash scripts/init.sh

# 5. Tout déployer en dev avec MetalLB + OpenFaaS
./kubernetes/deploy.sh --env dev --install-metallb --install-openfaas

# 6. Vérifier
kubectl get pods -A
kubectl -n kube-system get svc traefik   # doit avoir 192.168.1.240 en EXTERNAL-IP
curl -k -H 'Host: cofrap-dev.home-maurras.fr' http://192.168.1.240/healthz
```

### Recette 2 — Migration Phase 1 → Phase 2 (GitOps avec ArgoCD)

```bash
# Préalable : la stack tourne via deploy.sh, le secret .secrets.dev existe.

# 1. Installer ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# 2. Installer Image Updater + sa config
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml
# (créer le PAT GitHub d'abord — scope `repo` sur cofrap-stack)
kubectl -n argocd create secret generic git-creds \
  --from-literal=username=argocd-image-updater \
  --from-literal=password=<PAT>
kubectl apply -f kubernetes/argocd/image-updater-config.yaml
kubectl -n argocd rollout restart deployment argocd-image-updater

# 3. Pré-créer les secrets cofrap (ArgoCD ne les gère pas)
source kubernetes/.secrets.dev
kubectl -n openfaas-fn create secret generic encryption-key --from-literal=encryption-key="$ENCRYPTION_KEY" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n openfaas-fn create secret generic mariadb-password --from-literal=mariadb-password="$MARIADB_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -

# 4. Ajouter le repo cofrap-stack dans ArgoCD (avec submodules)
kubectl port-forward -n argocd svc/argocd-server 8443:443 &
argocd login localhost:8443 --insecure --username admin --password <pwd>
argocd repo add https://github.com/COFRAP-EPSI-2026/cofrap-stack.git \
  --username argocd-image-updater --password <PAT> --enable-submodule

# 5. Bootstrap GitOps
kubectl apply -f kubernetes/argocd/app-of-apps.dev.yaml

# 6. Vérifier que les 3 Applications passent en Synced/Healthy
argocd app list
# → cofrap-stack-dev / cofrap-backend-dev / cofrap-frontend-dev   Synced  Healthy
```

### Recette 3 — Rollback rapide en cas de problème en prod

```bash
# Voir l'historique
helm history cofrap -n cofrap
# REVISION    UPDATED        STATUS      CHART          DESCRIPTION
# 1           2026-05-10     superseded  cofrap-2026.3.0
# 2           2026-05-22     deployed    cofrap-2026.3.2

# Rollback à la révision précédente
helm rollback cofrap 1 -n cofrap

# Ou via ArgoCD (si en GitOps)
argocd app history cofrap-backend-prod
argocd app rollback cofrap-backend-prod 12   # ID de révision Argo
```

### Recette 4 — Mettre à jour une image en prod sans attendre Image Updater

```bash
# Modifier manuellement le tag dans Git
sed -i 's/^  tag: .*/  tag: "v2026.4.1"/' kubernetes/values/frontend.prod.yaml
git commit -am "chore: bump frontend to v2026.4.1"
git push

# ArgoCD voit le commit en ~30s et reconcilie.
# Pour accélérer (forcer une sync immédiate) :
argocd app sync cofrap-frontend-prod
```

### Recette 5 — Tout détruire sur un cluster (cleanup)

```bash
# Soft : seulement la stack COFRAP
./kubernetes/uninstall.sh --env dev

# Hard : aussi OpenFaaS et MetalLB
./kubernetes/uninstall.sh --env dev --purge-openfaas --purge-metallb

# Nuclear : tout le namespace (si bloqué en Terminating, cf. § Debug courant)
kubectl delete namespace cofrap-dev openfaas openfaas-fn argocd metallb-system --wait=false
```

---

## Aller plus loin

- 📘 Doc officielle [`kubectl`](https://kubernetes.io/docs/reference/kubectl/)
- 📘 Doc officielle [Helm](https://helm.sh/docs/)
- 📘 Doc officielle [K3s](https://docs.k3s.io/)
- 📘 Doc officielle [Minikube](https://minikube.sigs.k8s.io/docs/)
- 📘 Doc officielle [MetalLB](https://metallb.universe.tf/)
- 📘 Doc officielle [OpenFaaS](https://docs.openfaas.com/)
- 📘 Doc officielle [ArgoCD](https://argo-cd.readthedocs.io/)
- 📘 Doc officielle [ArgoCD Image Updater](https://argocd-image-updater.readthedocs.io/)
- 🛠️ [k9s](https://k9scli.io/) — TUI pour explorer le cluster (indispensable)
- 📋 [Cheatsheet officielle kubectl](https://kubernetes.io/docs/reference/kubectl/quick-reference/)
