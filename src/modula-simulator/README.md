# Modula WMS Simulator

Generates realistic CDM inventory events (Pick 45%, PutAway 30%, Adjustment 10%,
CycleCount 10%, Snapshot 5%) against an 8-item catalog with VLM tray/cell locations,
batch tracking, and reference documents — and posts them exactly like Modula would.
Single stdlib-only Python file: nothing to `pip install`.

## Prerequisites
- Python 3.8+ (`python3 --version` / `python --version` on Windows)
- For `MODE=api`: the caller app from the runbook Step 4 (`sp-modula-caller-dev`) —
  tenant id, client id, client secret — and the APIM gateway URL

## Run locally

### 1. Dry run — see what it generates (no network)
```bash
cd src/modula-simulator
MODE=dry-run DURATION_SEC=10 RATE_PER_MIN=60 python3 simulator.py
```

### 2. Fire real events at the dev environment
```bash
MODE=api \
TARGET_URL=https://apim-modint-dev.azure-api.net/modula-adapter/v1/inventory/events \
TENANT_ID=<your-tenant-guid> \
CLIENT_ID=<sp-modula-caller-dev-appId> \
CLIENT_SECRET=<its-secret> \
RATE_PER_MIN=30 DURATION_SEC=120 \
python3 simulator.py
```
Each event prints one line: `[OK ] 202 Pick msg=6f1c1b2e ...` = delivered through
APIM → adapter → Event Hub.

### Windows PowerShell
```powershell
$env:MODE="api"
$env:TARGET_URL="https://apim-modint-dev.azure-api.net/modula-adapter/v1/inventory/events"
$env:TENANT_ID="<tenant-guid>"; $env:CLIENT_ID="<appId>"; $env:CLIENT_SECRET="<secret>"
$env:RATE_PER_MIN="30"; $env:DURATION_SEC="120"
python src\modula-simulator\simulator.py
```

### 3. Failure-path testing (after a clean run works)
```bash
# 10% unknown item ids -> pass ingress, land in bronze, dead-letter at the D365
# adapter; verify via GET /d365-adapter/v1/processing/deadletters
UNMAPPED_RATE=0.1 RATE_PER_MIN=30 DURATION_SEC=60 MODE=api TARGET_URL=... \
TENANT_ID=... CLIENT_ID=... CLIENT_SECRET=... python3 simulator.py

# 10% schema-invalid events -> expect [ERR] 400 at ingress (nothing enters the pipe)
ERROR_RATE=0.1 RATE_PER_MIN=30 DURATION_SEC=60 MODE=api TARGET_URL=... \
TENANT_ID=... CLIENT_ID=... CLIENT_SECRET=... python3 simulator.py
```

## All settings
| Env var | Default | Purpose |
|---|---|---|
| `MODE` | `dry-run` | `api` posts via APIM; `dry-run` prints to stdout |
| `TARGET_URL` | — | Adapter events endpoint (required for `api`) |
| `TENANT_ID` / `CLIENT_ID` / `CLIENT_SECRET` | — | Entra ID caller app (required for `api`) |
| `SCOPE` | `api://modula-integration/.default` | Token scope |
| `RATE_PER_MIN` | `12` | Events per minute |
| `DURATION_SEC` | `300` | Run length; `0` = forever |
| `BATCH_SIZE` | `1` | >1 uses the `/batch` endpoint |
| `WAREHOUSE_ID` | `WH01` | Payload warehouse |
| `TENANT` | `TFFI` | controlMessage.tenant (D365 legal entity) |
| `SEED` | — | RNG seed for reproducible runs |
| `ERROR_RATE` | `0.0` | Fraction of intentionally invalid events |
| `UNMAPPED_RATE` | `0.0` | Fraction using unknown item ids (DLQ path) |

## Troubleshooting first runs
- `401` — token audience mismatch: the caller SP needs the application permission on
  `api://modula-integration` with admin consent granted.
- `404` from the adapter — the Container App is still on the placeholder quickstart
  image; APIM + auth are working, deploy the real adapter via the Actions workflow.
- `403` — RBAC still propagating on the adapter's Event Hub Data Sender role (~5 min).
- `409` — duplicate messageId; the simulator always generates fresh UUIDs, so this
  usually means a proxy retried your request.

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
