#
# init.ps1 - prepare le meta-depot cofrap-stack pour le developpement local.
#
#   1. recupere le code des sous-modules backend/ et frontend/
#   2. cree backend/.env avec une cle de chiffrement generee
#   3. affiche les commandes pour lancer la stack
#
# Idempotent : peut etre relance sans risque.
# Pour passer les sous-modules sur le dernier main : git submodule update --remote
#
$ErrorActionPreference = 'Stop'

# Racine du depot = dossier parent de scripts/
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Info($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "OK   : $m" -ForegroundColor Green }
function Warn($m) { Write-Host "WARN : $m" -ForegroundColor Yellow }

# --- 1. Pre-requis ----------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Error 'git est introuvable. Installe Git puis relance.'
  exit 1
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Warn 'docker introuvable - requis pour lancer le backend.' }
if (-not (Get-Command node   -ErrorAction SilentlyContinue)) { Warn 'node introuvable - requis pour lancer le frontend.' }

# --- 2. Sous-modules (backend + frontend) -----------------------------------
Info 'Recuperation des sous-modules backend/ et frontend/...'
git submodule sync --recursive
git submodule update --init --recursive
if ($LASTEXITCODE -ne 0) { Write-Error 'Echec de l''initialisation des sous-modules.'; exit 1 }
Ok 'Sous-modules a jour.'

# --- 3. Fichier .env du backend ---------------------------------------------
Info 'Configuration de backend/.env...'
$envFile    = Join-Path $Root 'backend\.env'
$envExample = Join-Path $Root 'backend\.env.example'
if (Test-Path $envFile) {
  Ok 'backend/.env existe deja - conserve.'
} elseif (Test-Path $envExample) {
  Copy-Item $envExample $envFile
  # Cle Fernet = base64 url-safe de 32 octets aleatoires
  $bytes = New-Object 'byte[]' 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($bytes)
  $key = [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_')
  (Get-Content $envFile) -replace '^ENCRYPTION_KEY=.*', "ENCRYPTION_KEY=$key" | Set-Content $envFile
  Ok 'backend/.env cree avec une ENCRYPTION_KEY generee.'
} else {
  Warn 'backend/.env.example introuvable - les sous-modules sont-ils initialises ?'
}

# --- 4. Prochaines etapes ---------------------------------------------------
Write-Host ''
Write-Host '------------------------------------------------------------'
Write-Host ' Meta-depot pret. Pour lancer la stack complete :'
Write-Host ''
Write-Host '   Backend    cd backend  ; docker compose up -d --build'
Write-Host '   Frontend   cd frontend ; yarn install ; yarn dev'
Write-Host ''
Write-Host ' Puis ouvrir : http://localhost:5173'
Write-Host '------------------------------------------------------------'
