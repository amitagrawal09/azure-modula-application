# Modula WMS Simulator

Generates realistic CDM inventory events (Pick 45%, PutAway 30%, Adjustment 10%,
CycleCount 10%, Snapshot 5%) against an 8-item catalog with VLM tray/cell locations,
batch tracking, and reference documents — and posts them exactly like Modula would.

## Quick start (local, no build — stdlib only)
```bash
# See what it generates
MODE=dry-run DURATION_SEC=10 RATE_PER_MIN=60 python3 simulator.py

# Fire at the dev environment
MODE=api \
TARGET_URL=https://apim-modint-dev.azure-api.net/modula-adapter/v1/inventory/events \
TENANT_ID=<tenant> CLIENT_ID=<sp-modula-caller-dev appId> CLIENT_SECRET=<secret> \
RATE_PER_MIN=30 DURATION_SEC=120 python3 simulator.py
```

## Failure-path testing
- `ERROR_RATE=0.1` — 10% of events missing a required field → expect 400s at ingress
- `UNMAPPED_RATE=0.1` — 10% use unknown item ids → flows to Event Hub, dead-letters
  at the D365 adapter (verify via GET /processing/deadletters); still lands in bronze
- `BATCH_SIZE=25` — exercises the /batch endpoint
- `SEED=42` — reproducible runs for comparing before/after

## Run as a Container App job (sustained load in Azure)
```bash
az acr build -r acrmodintdev -t modula-simulator:latest src/modula-simulator
az containerapp job create -g rg-modint-dev -n caj-modula-sim \
  --environment cae-modint-dev --trigger-type Manual \
  --image acrmodintdev.azurecr.io/modula-simulator:latest \
  --cpu 0.25 --memory 0.5Gi --replica-timeout 3900 \
  --env-vars MODE=api RATE_PER_MIN=60 DURATION_SEC=3600 \
    TARGET_URL=https://apim-modint-dev.azure-api.net/modula-adapter/v1/inventory/events \
    TENANT_ID=<tenant> CLIENT_ID=<appId> CLIENT_SECRET=secretref:sim-secret \
  --secrets sim-secret=<secret> --registry-server acrmodintdev.azurecr.io
az containerapp job start -g rg-modint-dev -n caj-modula-sim
```
