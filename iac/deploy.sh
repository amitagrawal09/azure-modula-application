#!/usr/bin/env bash
# One-command deployment: ./deploy.sh [env] [location]
set -euo pipefail
ENV="${1:-dev}"
LOCATION="${2:-eastus2}"

command -v az >/dev/null || { echo "Azure CLI not found — install from https://aka.ms/azcli"; exit 1; }
az account show >/dev/null 2>&1 || az login

echo "Deploying Modula integration platform: env=$ENV location=$LOCATION"
echo "Subscription: $(az account show --query name -o tsv)"
read -r -p "Continue? [y/N] " ok; [[ "$ok" == "y" || "$ok" == "Y" ]] || exit 0

az deployment sub create \
  --name "modint-$ENV-$(date +%Y%m%d%H%M%S)" \
  --location "$LOCATION" \
  --template-file "$(dirname "$0")/main.bicep" \
  --parameters env="$ENV" location="$LOCATION"

echo ""
echo "Done. Gateway URL:"
az deployment sub show -n "$(az deployment sub list --query "[?starts_with(name,'modint-$ENV')]|[0].name" -o tsv)" \
  --query properties.outputs.apimGatewayUrl.value -o tsv
