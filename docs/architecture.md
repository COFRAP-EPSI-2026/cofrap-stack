# Architecture COFRAP — vue d'ensemble

Diagrammes [Mermaid](https://mermaid.js.org/) (rendus nativement par GitHub) couvrant
trois angles complémentaires :

1. [**Architecture applicative — DEV**](#1-architecture-applicative--dev) : composants + flux GitOps
2. [**Architecture applicative — PROD**](#2-architecture-applicative--prod) : composants + déploiement scripté
3. [**Architecture réseau / infrastructure — DEV**](#3-architecture-réseau--infrastructure--dev)
4. [**Architecture réseau / infrastructure — PROD**](#4-architecture-réseau--infrastructure--prod)
5. [**Flux utilisateur**](#5-flux-utilisateur) : Register / Login / Renew (sequence diagram)

> Pour la prose détaillée (choix techniques, ADR), voir
> [`backend/docs/fr/architecture.md`](../backend/docs/fr/architecture.md) et
> [`frontend/docs/fr/architecture.md`](../frontend/docs/fr/architecture.md).
> Pour le mode de déploiement par env, voir [`kubernetes/README.md`](../kubernetes/README.md#architecture-par-environnement).

---

## 1. Architecture applicative — DEV

Mode **GitOps complet** : ArgoCD + Image Updater déploient automatiquement à chaque
push sur la branche `dev`.

```mermaid
flowchart TB
    classDef extSvc fill:#fef3c7,stroke:#d97706,color:#000
    classDef cluster fill:#e0f2fe,stroke:#0284c7,color:#000
    classDef ns fill:#f3e8ff,stroke:#7e22ce,color:#000
    classDef workload fill:#dcfce7,stroke:#16a34a,color:#000
    classDef gitops fill:#fee2e2,stroke:#dc2626,color:#000

    Dev["👤 Développeur"]
    GH["GitHub<br/>cofrap-backend / cofrap-frontend"]
    CI["GitHub Actions<br/>pre-release.yml"]
    GHCR["GHCR<br/>ghcr.io/cofrap-epsi-2026/*:dev"]

    Dev -- "git push origin dev" --> GH
    GH --> CI
    CI -- "build + push image :dev" --> GHCR

    subgraph K3SDev["Cluster K3s — DEV"]
        direction TB
        subgraph NSArgo["ns: argocd"]
            IU["ArgoCD Image Updater<br/>(stratégie: digest)"]:::gitops
            Argo["ArgoCD<br/>App-of-Apps cofrap-stack-dev"]:::gitops
        end

        subgraph NSCofrap["ns: cofrap-dev"]
            MariaDB[("MariaDB 12<br/>StatefulSet + PVC 1Gi")]:::workload
            FE["cofrap-frontend-dev<br/>nginx + SPA Vue 3"]:::workload
            SecBE["Secret<br/>cofrap-dev-mariadb-credentials"]:::ns
        end

        subgraph NSFn["ns: openfaas-fn"]
            GenPwd["generate-password<br/>(Python FastAPI)"]:::workload
            Gen2FA["generate-2fa"]:::workload
            AuthU["authenticate-user"]:::workload
            SecKey["Secret<br/>encryption-key"]:::ns
            SecPwd["Secret<br/>mariadb-password"]:::ns
        end

        subgraph NSOF["ns: openfaas"]
            GW["OpenFaaS Gateway"]:::workload
        end
    end

    GHCR -- "polling GHCR 2 min" --> IU
    IU -- "commit auto digest dans<br/>kubernetes/values/&lt;comp&gt;.dev.yaml" --> GH
    GH -- "polling Git 3 min" --> Argo
    Argo -- "helm template + apply<br/>(selfHeal: true)" --> NSCofrap
    Argo -- "helm template + apply" --> NSFn

    GenPwd -- "lit" --> SecKey
    Gen2FA -- "lit" --> SecKey
    AuthU -- "lit" --> SecKey
    GenPwd -- "lit" --> SecPwd
    Gen2FA -- "lit" --> SecPwd
    AuthU -- "lit" --> SecPwd
    GenPwd -- "SQL" --> MariaDB
    Gen2FA -- "SQL" --> MariaDB
    AuthU -- "SQL" --> MariaDB
    MariaDB -- "envFrom" --> SecBE

    FE -- "proxy /api/*" --> GW
    GW --> GenPwd
    GW --> Gen2FA
    GW --> AuthU

    class GH,CI,GHCR extSvc
    class K3SDev cluster
    class NSArgo,NSCofrap,NSFn,NSOF ns
```

**Points clés** :
- **`secrets.create: false`** : le chart ne crée plus les secrets — ils sont pré-créés via `kubernetes/create-secrets.sh --env dev` (gérés hors de Git).
- **Image Updater (stratégie digest)** suit le tag mobile `:dev` — chaque republication change le SHA256 → bump auto dans Git → ArgoCD reconcile.
- **`selfHeal: true`** : ArgoCD corrige automatiquement les drifts (quelqu'un modifie un pod à la main → ArgoCD le ramène à l'état Git).

---

## 2. Architecture applicative — PROD

Mode **scripté** (`deploy.sh`) : déploiement explicite et validé par l'humain.
**ArgoCD non activé** (mais activable — manifestes prêts dans [`kubernetes/argocd/`](../kubernetes/argocd/)).

```mermaid
flowchart TB
    classDef extSvc fill:#fef3c7,stroke:#d97706,color:#000
    classDef cluster fill:#e0f2fe,stroke:#0284c7,color:#000
    classDef ns fill:#f3e8ff,stroke:#7e22ce,color:#000
    classDef workload fill:#dcfce7,stroke:#16a34a,color:#000
    classDef optional fill:#fafafa,stroke:#9ca3af,color:#6b7280,stroke-dasharray: 5 5

    Ops["👤 Opérateur"]
    GH["GitHub<br/>cofrap-backend / cofrap-frontend"]
    RP["Release Please<br/>(PR → merge main)"]
    CI["GitHub Actions<br/>release-please.yml"]
    GHCR["GHCR<br/>ghcr.io/cofrap-epsi-2026/*:vX.Y.Z + :latest"]

    Ops -- "git push main + merge Release PR" --> GH
    GH --> RP
    RP -- "tag vX.Y.Z" --> CI
    CI -- "build + push multi-arch" --> GHCR

    Ops -- "./kubernetes/deploy.sh --env prod" --> Deploy
    Deploy["deploy.sh<br/>(helm upgrade --install)"]:::extSvc
    GHCR -. "pull image" .-> Deploy

    subgraph K3SProd["Cluster K3s — PROD"]
        direction TB
        subgraph NSCofrapP["ns: cofrap"]
            MariaDB[("MariaDB 12<br/>StatefulSet + PVC 2Gi")]:::workload
            FE["cofrap-frontend<br/>nginx + SPA Vue 3"]:::workload
            SecBE["Secret<br/>cofrap-mariadb-credentials"]:::ns
        end

        subgraph NSFnP["ns: openfaas-fn"]
            GenPwd["generate-password"]:::workload
            Gen2FA["generate-2fa"]:::workload
            AuthU["authenticate-user"]:::workload
            SecKey["Secret<br/>encryption-key"]:::ns
            SecPwd["Secret<br/>mariadb-password"]:::ns
        end

        subgraph NSOFP["ns: openfaas"]
            GW["OpenFaaS Gateway"]:::workload
        end

        subgraph NSArgoOpt["ns: argocd (OPTIONNEL — activable)"]
            ArgoOpt["ArgoCD + Image Updater<br/>(stratégie: semver vX.Y.Z)"]:::optional
        end
    end

    Deploy -- "helm upgrade --install<br/>(passe secrets via --set)" --> NSCofrapP
    Deploy -- "helm upgrade --install" --> NSFnP

    GenPwd -- "lit" --> SecKey
    Gen2FA -- "lit" --> SecKey
    AuthU -- "lit" --> SecKey
    GenPwd -- "SQL" --> MariaDB
    Gen2FA -- "SQL" --> MariaDB
    AuthU -- "SQL" --> MariaDB
    MariaDB -- "envFrom" --> SecBE

    FE -- "proxy /api/*" --> GW
    GW --> GenPwd
    GW --> Gen2FA
    GW --> AuthU

    GHCR -. "polling (si activé)" .-> ArgoOpt
    ArgoOpt -. "reconcile (si activé)" .-> NSCofrapP

    class GH,RP,CI,GHCR extSvc
    class K3SProd cluster
    class NSCofrapP,NSFnP,NSOFP,NSArgoOpt ns
```

**Différences vs DEV** :
- **`secrets.create: true`** (défaut) : le chart crée les 3 secrets à partir des valeurs passées par `deploy.sh --set`.
- **Tags semver immuables** (`v2026.X.Y`) au lieu du mobile `:dev`.
- **PVC MariaDB 2Gi** (vs 1Gi en dev).
- **ArgoCD désactivé** — bloc en pointillé : prêt à l'emploi le jour où tu veux passer en GitOps (cf. [`kubernetes/README.md` § Activer ArgoCD en prod](../kubernetes/README.md#activer-argocd-en-prod-plus-tard-optionnel)).
- **selfHeal: false** quand ArgoCD est activé (humain dans la boucle).

---

## 3. Architecture réseau / infrastructure — DEV

```mermaid
flowchart LR
    classDef extWeb fill:#fef3c7,stroke:#d97706,color:#000
    classDef edge fill:#fce7f3,stroke:#be185d,color:#000
    classDef lan fill:#dbeafe,stroke:#1d4ed8,color:#000
    classDef k8s fill:#dcfce7,stroke:#16a34a,color:#000

    User["🌐 Utilisateur<br/>(navigateur)"]:::extWeb
    DNS["DNS Cloudflare<br/>cofrap-dev.home-maurras.fr<br/>(CNAME proxied)"]:::edge
    CFE["Cloudflare Edge<br/>(TLS termination,<br/>WAF, CDN)"]:::edge

    subgraph Home["🏠 Réseau LAN — 192.168.1.0/24"]
        direction TB
        CFD["cloudflared<br/>(daemon Tunnel)<br/>↕ TLS sortant vers CF"]:::lan
        Box["Box internet<br/>(pas de port ouvert)"]:::lan

        subgraph K3sDev["Cluster K3s DEV"]
            direction TB
            VIP[/"VIP MetalLB L2<br/>192.168.1.240:80"/]:::k8s
            Traefik["Service traefik<br/>(LoadBalancer)<br/>+ Ingress controller"]:::k8s
            IngFE["Ingress cofrap-frontend-dev<br/>host: cofrap-dev.home-maurras.fr"]:::k8s
            IngArgo["Ingress argocd-server<br/>host: argocd-dev.home-maurras.fr"]:::k8s
            SvcFE["Service cofrap-frontend-dev<br/>(ClusterIP)"]:::k8s
            SvcArgo["Service argocd-server<br/>(ClusterIP)"]:::k8s
            PodFE["Pod nginx<br/>SPA + proxy /api"]:::k8s
            SvcGW["Service gateway<br/>(openfaas ns)"]:::k8s
            PodsFn["Pods fonctions<br/>(openfaas-fn ns)"]:::k8s
            PodArgo["Pod argocd-server"]:::k8s
        end
    end

    User -- "HTTPS :443" --> DNS
    DNS --> CFE
    CFE -- "TLS interne tunnel" --> CFD
    CFD -- "HTTP" --> VIP
    Box -. "❌ aucun port ouvert" .- CFE

    VIP --> Traefik
    Traefik -- "Host: cofrap-dev..." --> IngFE
    Traefik -- "Host: argocd-dev..." --> IngArgo
    IngFE --> SvcFE --> PodFE
    IngArgo --> SvcArgo --> PodArgo
    PodFE -- "/api/* → proxy_pass<br/>(même origine, pas de CORS)" --> SvcGW
    SvcGW --> PodsFn
```

**Points clés réseau** :
- **Cloudflare Tunnel sortant uniquement** : aucun port n'est ouvert sur ta box. Le daemon `cloudflared` initie la connexion vers Cloudflare → pas d'exposition directe.
- **MetalLB en mode L2** : annonce l'IP virtuelle `192.168.1.240` sur le LAN via ARP. Le Service `traefik` (LoadBalancer) prend cette IP, stable et indépendante du nœud K3s qui tourne le pod traefik.
- **Path field VIDE** dans le Cloudflare Tunnel (piège classique : `^/` ou autre regex casse tout).
- **Frontend proxifie `/api/*` côté nginx du pod** vers le gateway OpenFaaS interne — même origine pour le navigateur → aucun CORS.

---

## 4. Architecture réseau / infrastructure — PROD

Identique à dev sauf hostnames et IP MetalLB. Aucun port exposé sur la box.

```mermaid
flowchart LR
    classDef extWeb fill:#fef3c7,stroke:#d97706,color:#000
    classDef edge fill:#fce7f3,stroke:#be185d,color:#000
    classDef lan fill:#dbeafe,stroke:#1d4ed8,color:#000
    classDef k8s fill:#dcfce7,stroke:#16a34a,color:#000

    User["🌐 Utilisateur<br/>(navigateur)"]:::extWeb
    DNS["DNS Cloudflare<br/>cofrap.home-maurras.fr<br/>(CNAME proxied)"]:::edge
    CFE["Cloudflare Edge<br/>(TLS, WAF, CDN)"]:::edge

    subgraph Home["🏠 Réseau LAN — 192.168.1.0/24"]
        direction TB
        CFD["cloudflared (daemon Tunnel)"]:::lan
        Box["Box internet<br/>(pas de port ouvert)"]:::lan

        subgraph K3sProd["Cluster K3s PROD"]
            direction TB
            VIP[/"VIP MetalLB L2<br/>192.168.1.241:80"/]:::k8s
            Traefik["Service traefik (LoadBalancer)<br/>+ Ingress controller"]:::k8s
            IngFE["Ingress cofrap-frontend<br/>host: cofrap.home-maurras.fr"]:::k8s
            SvcFE["Service cofrap-frontend"]:::k8s
            PodFE["Pod nginx + SPA"]:::k8s
            SvcGW["Service gateway (openfaas ns)"]:::k8s
            PodsFn["Pods fonctions (openfaas-fn ns)"]:::k8s
        end
    end

    User -- "HTTPS :443" --> DNS
    DNS --> CFE
    CFE -- "TLS interne tunnel" --> CFD
    CFD -- "HTTP" --> VIP
    Box -. "❌ aucun port ouvert" .- CFE

    VIP --> Traefik
    Traefik -- "Host: cofrap..." --> IngFE
    IngFE --> SvcFE --> PodFE
    PodFE -- "/api/* → proxy_pass" --> SvcGW
    SvcGW --> PodsFn
```

**Différences vs DEV** :
- Hostname `cofrap.home-maurras.fr` (vs `cofrap-dev.…`)
- VIP MetalLB `192.168.1.241` (vs `.240`)
- Pas d'Ingress ArgoCD (ArgoCD non activé en prod)
- Cloudflared peut être **le même daemon** que dev (1 tunnel, 2 public hostnames) ou un daemon distinct selon ta topologie.

---

## 5. Flux utilisateur

### 5.1 Création de compte (Register)

```mermaid
sequenceDiagram
    actor U as 👤 Utilisateur
    participant FE as 🖥 Frontend Vue 3
    participant GP as generate-password
    participant G2 as generate-2fa
    participant AU as authenticate-user
    participant DB as MariaDB

    Note over U,FE: Étape 1 — saisie du username
    U->>FE: ouvre /register, saisit username
    FE->>GP: POST /api/function/generate-password { username }
    GP->>GP: génère mot de passe 24 char (4 classes)
    GP->>GP: chiffre avec Fernet
    GP->>DB: INSERT users (username, password_chiffré, gendate)
    GP->>GP: génère QR PNG (contient le mdp en clair)
    GP-->>FE: { username, qrcode_png_base64, gendate }

    Note over U,FE: Étape 2 — affichage du mot de passe
    FE->>FE: jsQR décode le PNG côté navigateur
    FE->>U: affiche QR + bouton Eye/Copy<br/>(mdp jamais transmis en JSON)
    U->>U: scanne le QR ou copie le mdp<br/>(stocke dans son coffre)

    Note over U,FE: Étape 3 — activation 2FA
    U->>FE: clique "Activer la 2FA"
    FE->>G2: POST /api/function/generate-2fa { username }
    G2->>G2: génère secret TOTP base32 + URI otpauth://
    G2->>G2: chiffre avec Fernet
    G2->>DB: UPDATE users SET mfa=secret_chiffré
    G2->>G2: génère QR otpauth
    G2-->>FE: { otpauth_uri, qrcode_png_base64 }
    FE->>U: affiche QR TOTP
    U->>U: scanne avec Google Authenticator
    U->>FE: saisit le code à 6 chiffres

    Note over U,FE: Étape 4 — confirmation
    FE->>AU: POST /api/function/authenticate-user<br/>{ username, password, otp }
    AU->>DB: SELECT users WHERE username
    AU->>AU: déchiffre password + mfa<br/>vérifie pyotp.TOTP.verify(otp)
    AU-->>FE: { authenticated: true, username }
    FE->>U: ✓ compte créé, redirection vers /login
```

### 5.2 Authentification (Login)

```mermaid
flowchart TD
    Start([👤 Utilisateur sur /login]) --> S1[Saisit username + password]
    S1 --> S2[Saisit le code TOTP à 6 chiffres]
    S2 --> POST["POST /api/function/authenticate-user<br/>{ username, password, otp }"]
    POST --> DB[(MariaDB : SELECT user)]
    DB --> Check{Credentials valides<br/>+ TOTP valide ?}

    Check -- "Non" --> Fail[401 invalid credentials/otp]
    Fail --> LockCheck{≥ 5 échecs<br/>en 10 min ?}
    LockCheck -- "Oui" --> Lockout[localStorage:<br/>verrouillage 15 min]
    LockCheck -- "Non" --> S1
    Lockout --> S1

    Check -- "Oui" --> ExpCheck{now - gendate<br/>&gt; 6 mois ?}
    ExpCheck -- "Oui" --> Expired["Réponse :<br/>{ authenticated: false,<br/>expired: true,<br/>action: regenerate_password_and_2fa }"]
    Expired --> Redirect[Redirection vers /renew]

    ExpCheck -- "Non" --> OK[✓ Authentifié<br/>localStorage.cofrap-user]
    OK --> Home[Redirection vers /]

    classDef ok fill:#dcfce7,stroke:#16a34a
    classDef ko fill:#fee2e2,stroke:#dc2626
    classDef neutral fill:#dbeafe,stroke:#1d4ed8
    class OK,Home ok
    class Fail,Lockout,Expired ko
    class Redirect neutral
```

### 5.3 Renouvellement (Renew)

Déclenché par Login quand `expired: true`. Même flux que Register, mais le user existe déjà.

```mermaid
flowchart TD
    Start([👤 Utilisateur sur /renew<br/>après Login expiré]) --> S1[Confirme son username]
    S1 --> R1["POST /api/function/generate-password<br/>(remplace l'ancien mdp chiffré)"]
    R1 --> Show[Affiche QR + mdp décodé<br/>via jsQR — étape Register]
    Show --> R2["POST /api/function/generate-2fa<br/>(remplace l'ancien secret TOTP)"]
    R2 --> Scan[User scanne le nouveau QR TOTP]
    Scan --> R3["POST /api/function/authenticate-user<br/>{ username, password, otp }"]
    R3 --> Reset["Backend :<br/>expired = 0<br/>gendate = now()"]
    Reset --> OK[✓ Identifiants renouvelés<br/>redirection vers /login]

    classDef ok fill:#dcfce7,stroke:#16a34a
    class OK,Reset ok
```

---

## Liens vers la doc opérationnelle

- 🚀 [`runbook-dev.md`](runbook-dev.md) — déploiement dev A → Z (GitOps actif)
- 🚀 [`runbook-prod.md`](runbook-prod.md) — déploiement prod A → Z (scripté, ArgoCD optionnel)
- 📋 [`cheatsheet.md`](cheatsheet.md) — commandes courantes (kubectl, helm, argocd…)
- 🏗 [`../kubernetes/README.md`](../kubernetes/README.md) — détail des scripts + Phase 1
- 🤖 [`../kubernetes/argocd/README.md`](../kubernetes/argocd/README.md) — détail GitOps + Image Updater
- 🔒 [`../backend/docs/fr/security.md`](../backend/docs/fr/security.md) — modèle de menace, rate-limit, rotation
