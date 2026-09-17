# Deployment Options

## Option 1 — Deploy to Azure button (single click, portal)
Push this repo (or just `iac/azuredeploy.json`) to GitHub, then this button gives a
portal-driven deployment with a parameter form (env, location, namePrefix):

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Ftffi%2Fazure-modula-application%2Fmain%2Fiac%2Fazuredeploy.json)

If the repo lives elsewhere, URL-encode the raw path to `azuredeploy.json` and substitute
it after `/uri/`. The template is **subscription scope** — the portal will ask for a
deployment region and subscription, then create resource group `rg-modint-<env>` itself.
The button target must be publicly reachable (public repo, or a Blob/SAS URL for private repos).

## Option 2 — One command (CLI)
```bash
./iac/deploy.sh dev eastus2        # bash / Cloud Shell
.\iac\deploy.ps1 -Env dev          # PowerShell
```
Both scripts handle login, confirm the target subscription, deploy, and print the APIM gateway URL.

## Option 3 — Raw Azure CLI
```bash
az deployment sub create -l eastus2 -f iac/main.bicep -p env=dev
```

## What gets deployed
Resource group `rg-modint-<env>` containing: VNet + private DNS, Log Analytics + App
Insights + action group, Key Vault, ADLS Gen2 storage (capture/checkpoints/bronze/
quarantine), Event Hubs namespace with `inventory-events` + consumer groups + schema
group, Service Bus DLQs, ACR + Container Apps environment + 3 adapter apps (placeholder
images until first CI/CD run), APIM with policies, and all managed-identity RBAC.

## After first deploy
Run the GitHub Actions workflow (`iac/deploy-apis.yaml`) or `az acr build` +
`az containerapp update` per adapter to replace the placeholder images, then complete
the post-deploy steps in README.md (Key Vault secrets, schema registration, Modula
webhook, Databricks external location).

## Notes
- Re-running is safe: everything is idempotent ARM/Bicep.
- `azuredeploy.json` is compiled from `main.bicep` — regenerate after Bicep changes:
  `az bicep build -f iac/main.bicep --outfile iac/azuredeploy.json`
- APIM provisioning takes 30–45 min on first deploy; everything else is minutes.
