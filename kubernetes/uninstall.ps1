#requires -Version 7

<#
.SYNOPSIS
    Supprime la stack COFRAP (dev ou prod) du cluster K8s.

.DESCRIPTION
    Équivalent PowerShell de uninstall.sh. Désinstalle les 2 releases Helm,
    supprime les secrets cofrap dans openfaas-fn, les PVC MariaDB et le namespace.
    OpenFaaS et MetalLB sont conservés sauf -PurgeOpenfaas / -PurgeMetallb.

.PARAMETER Env
    Environnement cible : dev ou prod.

.PARAMETER PurgeOpenfaas
    Désinstalle aussi OpenFaaS Community.

.PARAMETER PurgeMetallb
    Désinstalle aussi MetalLB (impacte tous les LoadBalancer du cluster).

.PARAMETER KeepSecrets
    Conserve le cache .secrets.<env> (par défaut : supprimé).
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('dev', 'prod')]
  [string]$Env,

  [switch]$PurgeOpenfaas,
  [switch]$PurgeMetallb,
  [switch]$KeepSecrets
)

$ErrorActionPreference = 'Stop'

function Info($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "   ✓ $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "   ! $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "`n✗ $msg" -ForegroundColor Red; exit 1 }

$Root    = (Get-Item $PSScriptRoot).Parent.FullName
$KubeDir = $PSScriptRoot

$EnvFile = Join-Path $KubeDir "env\$Env.env"
if (-not (Test-Path $EnvFile)) { Die "Fichier d'env introuvable : $EnvFile" }

Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*([^#]*?)\s*(?:#.*)?$' -and -not $_.TrimStart().StartsWith('#')) {
    Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
  }
}

Info "Désinstallation COFRAP — env: $Env / namespace: $env:NAMESPACE"

# --- 1. Helm releases ----------------------------------------------------
Info "Désinstallation des releases Helm"
try { helm uninstall $env:RELEASE_FRONTEND -n $env:NAMESPACE 2>$null; Ok "Frontend supprimé" }
catch { Warn "Frontend non trouvé" }
try { helm uninstall $env:RELEASE_BACKEND  -n $env:NAMESPACE 2>$null; Ok "Backend supprimé" }
catch { Warn "Backend non trouvé" }

# --- 2. Secrets dans openfaas-fn -----------------------------------------
Info "Nettoyage des secrets dans $env:OPENFAAS_FN_NAMESPACE"
kubectl -n $env:OPENFAAS_FN_NAMESPACE delete secret mariadb-password encryption-key --ignore-not-found
Ok "Secrets MariaDB + Fernet supprimés"

# --- 3. PVC MariaDB ------------------------------------------------------
Info "Suppression des PVC MariaDB dans $env:NAMESPACE"
kubectl -n $env:NAMESPACE delete pvc -l 'app.kubernetes.io/name=mariadb' --ignore-not-found
Ok "PVC MariaDB supprimés (données perdues)"

# --- 4. Namespace --------------------------------------------------------
Info "Suppression du namespace $env:NAMESPACE"
kubectl delete namespace $env:NAMESPACE --ignore-not-found --wait=false
Ok "Namespace en cours de suppression"

# --- 5. OpenFaaS (opt-in) ------------------------------------------------
if ($PurgeOpenfaas) {
  Info "Désinstallation d'OpenFaaS Community"
  try { helm uninstall openfaas -n $env:OPENFAAS_NAMESPACE 2>$null } catch { Warn "OpenFaaS non trouvé" }
  kubectl delete namespace $env:OPENFAAS_NAMESPACE $env:OPENFAAS_FN_NAMESPACE --ignore-not-found --wait=false
  Ok "OpenFaaS supprimé"
}

# --- 6. MetalLB (opt-in) -------------------------------------------------
if ($PurgeMetallb) {
  Info "Désinstallation de MetalLB"
  kubectl delete -f (Join-Path $KubeDir "loadbalancing\metallb-pool.$Env.yaml") --ignore-not-found
  kubectl delete -f (Join-Path $KubeDir "loadbalancing\metallb-native.yaml")      --ignore-not-found
  Ok "MetalLB supprimé"
}

# --- 7. Cache secrets ----------------------------------------------------
$SecretsFile = Join-Path $KubeDir ".secrets.$Env"
if ((Test-Path $SecretsFile) -and (-not $KeepSecrets)) {
  Remove-Item $SecretsFile -Force
  Ok "Cache .secrets.$Env supprimé"
} elseif (Test-Path $SecretsFile) {
  Warn "Cache .secrets.$Env conservé (-KeepSecrets)"
}

Info "Désinstallation terminée ✓"
