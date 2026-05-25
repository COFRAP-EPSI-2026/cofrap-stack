#requires -Version 7

<#
.SYNOPSIS
    Déploie la stack COFRAP complète (dev ou prod) sur un cluster K8s.

.DESCRIPTION
    Équivalent PowerShell de deploy.sh. Enchaîne :
      1. Vérifie kubectl + helm + accès cluster
      2. (-InstallMetallb)  Applique MetalLB + pool d'IPs de l'env
      3. (-InstallOpenfaas) Installe OpenFaaS Community via Helm
      4. Génère/récupère les secrets (Fernet key + 2 mots de passe MariaDB)
      5. Déploie le chart backend  (cofrap)
      6. Déploie le chart frontend (cofrap-frontend)
      7. Affiche le récap

    Idempotent — les secrets sont mis en cache dans `.secrets.<env>` (gitignoré).

.PARAMETER Env
    Environnement cible : dev ou prod.

.PARAMETER InstallMetallb
    Installe MetalLB. Par défaut : skippé (assumé déjà installé).

.PARAMETER InstallOpenfaas
    Installe OpenFaaS Community. Par défaut : skippé.

.EXAMPLE
    .\kubernetes\deploy.ps1 -Env dev
    .\kubernetes\deploy.ps1 -Env prod -InstallMetallb -InstallOpenfaas
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('dev', 'prod')]
  [string]$Env,

  [switch]$InstallMetallb,
  [switch]$InstallOpenfaas
)

$ErrorActionPreference = 'Stop'

# --- Helpers --------------------------------------------------------------
function Info($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "   ✓ $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "   ! $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "`n✗ $msg" -ForegroundColor Red; exit 1 }

$Root    = (Get-Item $PSScriptRoot).Parent.FullName
$KubeDir = $PSScriptRoot

# --- Charge les variables d'environnement --------------------------------
$EnvFile = Join-Path $KubeDir "env\$Env.env"
if (-not (Test-Path $EnvFile)) { Die "Fichier d'env introuvable : $EnvFile" }

# Parse le fichier KEY=VALUE et exporte dans $env:
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$' -and -not $_.StartsWith('#')) {
    Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
  }
}

Info "Déploiement COFRAP — environnement: $Env"
Write-Host "   Namespace       : $env:NAMESPACE"
Write-Host "   Release backend : $env:RELEASE_BACKEND"
Write-Host "   Release front   : $env:RELEASE_FRONTEND"
Write-Host "   Ingress host    : $env:INGRESS_HOST"
Write-Host "   MetalLB IP      : $env:METALLB_IP"
Write-Host "   Tag backend     : $env:IMAGE_TAG_BACKEND"
Write-Host "   Tag frontend    : $env:IMAGE_TAG_FRONTEND"

# --- 1. Pré-requis --------------------------------------------------------
Info "Vérification des pré-requis"
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { Die "kubectl introuvable" }
if (-not (Get-Command helm    -ErrorAction SilentlyContinue)) { Die "helm introuvable" }
try { kubectl cluster-info 2>$null | Out-Null } catch { Die "kubectl ne peut pas joindre le cluster" }
Ok "kubectl + helm + cluster OK"

# --- 2. MetalLB (optionnel) ----------------------------------------------
if ($InstallMetallb) {
  Info "Installation de MetalLB (manifeste natif)"
  kubectl apply -f (Join-Path $KubeDir "loadbalancing\metallb-native.yaml")
  try { kubectl -n metallb-system wait --for=condition=Ready pod --all --timeout=120s } catch {}
  kubectl apply -f (Join-Path $KubeDir "loadbalancing\metallb-pool.$Env.yaml")
  Ok "MetalLB installé + pool $Env appliqué ($env:METALLB_IP)"
} else {
  Warn "MetalLB skippé (assumé déjà installé). -InstallMetallb pour forcer."
}

# --- 3. OpenFaaS (optionnel) ---------------------------------------------
if ($InstallOpenfaas) {
  Info "Installation d'OpenFaaS Community"
  helm repo add openfaas https://openfaas.github.io/faas-netes/ | Out-Null
  helm repo update | Out-Null
  kubectl create namespace $env:OPENFAAS_NAMESPACE    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace $env:OPENFAAS_FN_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install openfaas openfaas/openfaas `
    --namespace $env:OPENFAAS_NAMESPACE `
    --set functionNamespace=$env:OPENFAAS_FN_NAMESPACE `
    --set generateBasicAuth=true `
    --wait --timeout 5m
  Ok "OpenFaaS installé dans $env:OPENFAAS_NAMESPACE"
} else {
  Warn "OpenFaaS skippé (assumé déjà installé). -InstallOpenfaas pour forcer."
}

# --- 4. Secrets (idempotent — cache dans .secrets.<env>) -----------------
$SecretsFile = Join-Path $KubeDir ".secrets.$Env"
if (Test-Path $SecretsFile) {
  Info "Réutilisation des secrets existants ($SecretsFile)"
  Get-Content $SecretsFile | ForEach-Object {
    if ($_ -match "^([A-Z_]+)=['""]?(.*?)['""]?$" -and -not $_.StartsWith('#')) {
      Set-Variable -Name $Matches[1] -Value $Matches[2] -Scope Script
    }
  }
  Ok "Secrets chargés depuis le cache"
} else {
  Info "Génération de nouveaux secrets"

  # Fernet key : 32 octets URL-safe base64
  if (Get-Command python -ErrorAction SilentlyContinue) {
    $script:ENCRYPTION_KEY = (python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())').Trim()
  } else {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $b64 = [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_')
    $script:ENCRYPTION_KEY = $b64
  }

  $script:MARIADB_PASSWORD = -join ((48..57) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
  $script:MARIADB_ROOT_PASSWORD = -join ((48..57) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })

  @"
# Secrets générés le $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') pour env=$Env.
# NE PAS COMMITER. Supprimer pour régénérer (perte des données chiffrées).
ENCRYPTION_KEY='$script:ENCRYPTION_KEY'
MARIADB_PASSWORD='$script:MARIADB_PASSWORD'
MARIADB_ROOT_PASSWORD='$script:MARIADB_ROOT_PASSWORD'
"@ | Set-Content -Path $SecretsFile -Encoding UTF8
  Ok "Secrets générés et mis en cache ($SecretsFile)"
}

# --- 5. Backend (chart cofrap) -------------------------------------------
Info "Déploiement du backend (chart cofrap → release $env:RELEASE_BACKEND)"
helm upgrade --install $env:RELEASE_BACKEND (Join-Path $Root "backend\deploy\helm\cofrap") `
  --namespace $env:NAMESPACE --create-namespace `
  --values (Join-Path $KubeDir "values\backend.$Env.yaml") `
  --set secrets.encryptionKey="$script:ENCRYPTION_KEY" `
  --set secrets.mariadbPassword="$script:MARIADB_PASSWORD" `
  --set secrets.mariadbRootPassword="$script:MARIADB_ROOT_PASSWORD" `
  --set functions.version="$env:IMAGE_TAG_BACKEND" `
  --wait --timeout 10m
Ok "Backend déployé"

# --- 6. Frontend (chart cofrap-frontend) ---------------------------------
Info "Déploiement du frontend (chart cofrap-frontend → release $env:RELEASE_FRONTEND)"
helm upgrade --install $env:RELEASE_FRONTEND (Join-Path $Root "frontend\deploy\helm\cofrap-frontend") `
  --namespace $env:NAMESPACE --create-namespace `
  --values (Join-Path $KubeDir "values\frontend.$Env.yaml") `
  --set image.tag="$env:IMAGE_TAG_FRONTEND" `
  --set ingress.host="$env:INGRESS_HOST" `
  --wait --timeout 5m
Ok "Frontend déployé"

# --- 7. Récap -------------------------------------------------------------
Info "Stack COFRAP déployée ✓"
@"

  Environnement     : $Env
  Namespace         : $env:NAMESPACE
  Hostname public   : https://$env:INGRESS_HOST
  IP MetalLB (VIP)  : $env:METALLB_IP

  Vérifier les pods :
    kubectl -n $env:NAMESPACE get pods
    kubectl -n $env:OPENFAAS_FN_NAMESPACE get pods -l 'faas_function'

  Mot de passe admin OpenFaaS :
    `$pwd = kubectl -n $env:OPENFAAS_NAMESPACE get secret basic-auth ``
      -o jsonpath='{.data.basic-auth-password}'
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$pwd))

  Re-déployer sans regénérer les secrets : relancer ce script.
  Supprimer la stack : .\kubernetes\uninstall.ps1 -Env $Env

"@
