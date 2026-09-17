# One-command deployment: .\deploy.ps1 -Env dev -Location eastus2
param(
  [ValidateSet('dev','test','prod')][string]$Env = 'dev',
  [string]$Location = 'eastus2'
)
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI not found — https://aka.ms/azcli' }
try { az account show | Out-Null } catch { az login }

Write-Host "Deploying Modula integration platform: env=$Env location=$Location" -ForegroundColor Cyan
Write-Host "Subscription: $(az account show --query name -o tsv)"
if ((Read-Host 'Continue? [y/N]') -notin @('y','Y')) { exit }

az deployment sub create `
  --name "modint-$Env-$(Get-Date -Format yyyyMMddHHmmss)" `
  --location $Location `
  --template-file "$PSScriptRoot/main.bicep" `
  --parameters env=$Env location=$Location
