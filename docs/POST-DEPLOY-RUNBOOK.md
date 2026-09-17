# Post-Deployment Runbook — Modula Integration (dev)

Resource names below assume `env=dev`, `namePrefix=modint`:
`rg-modint-dev`, `evhns-modint-dev`, `kv-modint-dev`, `stmodintdev`, `apim-modint-dev`,
`ca-modula-adapter-dev`, `ca-d365-adapter-dev`, `ca-datahub-adapter-dev`.

```bash
RG=rg-modint-dev
EVHNS=evhns-modint-dev
KV=kv-modint-dev
SA=stmodintdev
APIM=apim-modint-dev
TENANT_ID=$(az account show --query tenantId -o tsv)
```

---

## Step 1 — Register the CDM schema in the `inventory-cdm` schema group

The schema group already exists (created by Bicep, type JSON, compatibility None).
Registering the schema itself is a data-plane operation — it cannot be done in Bicep or
the portal's ARM view. Two options:

### Option A — Portal
1. Portal → Event Hubs namespace `evhns-modint-dev` → **Schema Registry** (left menu).
2. Open schema group **inventory-cdm** → **+ Schema**.
3. Name: `InventoryEventEnvelope` (this becomes the schema's identifier; keep it stable).
4. Paste the full contents of `cdm/inventory-event-cdm.schema.json` → **Create**.
5. Version 1 is now registered; future uploads under the same name create version 2, 3, …

### Option B — CLI/REST (repeatable, put this in the pipeline)
There is no `az` subcommand for schema registration yet; use the REST API with your AAD token:

```bash
TOKEN=$(az account get-access-token --resource https://eventhubs.azure.net --query accessToken -o tsv)

curl -X PUT \
  "https://$EVHNS.servicebus.windows.net/\$schemagroups/inventory-cdm/schemas/InventoryEventEnvelope?api-version=2020-09-01-preview" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json; serialization=Json" \
  --data-binary @cdm/inventory-event-cdm.schema.json
```

A `200/204` with `Schema-Id` and `Schema-Version` headers confirms registration.
Your identity needs the **Schema Registry Contributor** role on the namespace for this call:

```bash
az role assignment create \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --role "Schema Registry Contributor (Preview)" \
  --scope $(az eventhubs namespace show -g $RG -n $EVHNS --query id -o tsv)
```

The Modula adapter should also get **Schema Registry Reader** so it can validate against
the registered schema at publish time (add alongside its existing Data Sender role):

```bash
PRINCIPAL=$(az containerapp show -g $RG -n ca-modula-adapter-dev --query identity.principalId -o tsv)
az role assignment create --assignee $PRINCIPAL \
  --role "Schema Registry Reader (Preview)" \
  --scope $(az eventhubs namespace show -g $RG -n $EVHNS --query id -o tsv)
```

---

## Step 2 — Store D365 service principal + Modula API creds in Key Vault

### 2.1 Create the D365 service principal (if not already existing)
```bash
SP=$(az ad sp create-for-rbac --name "sp-modint-d365-dev" --skip-assignment -o json)
D365_CLIENT_ID=$(echo $SP | jq -r .appId)
D365_CLIENT_SECRET=$(echo $SP | jq -r .password)
```

Then register it inside D365 F&O (this part is in D365, not Azure):
1. D365 F&O → **System administration → Setup → Microsoft Entra ID applications**.
2. New record: Client Id = `$D365_CLIENT_ID`, Name = `Modula Integration`,
   User ID = a dedicated integration user (e.g. `MODULA-INT`) with a security role
   scoped to inventory journals / Inventory Visibility (do **not** use an admin account).
3. If using the **Inventory Visibility** add-in, also register the app under
   Inventory Visibility → Settings → App registration per its own onboarding.

### 2.2 Grant yourself temporary secret-write access, store secrets, revoke
The vault is RBAC-authorized; the adapters have Secrets **User** (read) only.

```bash
KV_ID=$(az keyvault show -n $KV --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee $ME --role "Key Vault Secrets Officer" --scope $KV_ID

az keyvault secret set --vault-name $KV -n d365-client-id     --value "$D365_CLIENT_ID"
az keyvault secret set --vault-name $KV -n d365-client-secret --value "$D365_CLIENT_SECRET"
az keyvault secret set --vault-name $KV -n d365-tenant-id     --value "$TENANT_ID"
az keyvault secret set --vault-name $KV -n d365-base-url      --value "https://<your-env>.operations.dynamics.com"
az keyvault secret set --vault-name $KV -n modula-api-key     --value "<key issued by Modula WMS>"
az keyvault secret set --vault-name $KV -n modula-base-url    --value "https://<modula-host>/api"

# optional hygiene: remove your write role when done
az role assignment delete --assignee $ME --role "Key Vault Secrets Officer" --scope $KV_ID
```

Secret names above are what the adapters expect via `KEYVAULT_URI` + managed identity
(DefaultAzureCredential); no restart needed if the adapter reads secrets lazily —
otherwise restart the revision:

```bash
az containerapp revision restart -g $RG -n ca-d365-adapter-dev \
  --revision $(az containerapp revision list -g $RG -n ca-d365-adapter-dev --query "[0].name" -o tsv)
```

### 2.3 Verify the adapter can read them
```bash
az containerapp exec -g $RG -n ca-d365-adapter-dev --command sh   # if shell available
# or simply check the adapter's /health endpoint, which reports d365Reachable
```

---

## Step 3 — Grant the DataHub adapter access to Databricks / Unity Catalog bronze

Goal: the adapter's managed identity writes JSON to `abfss://bronze@stmodintdev.dfs.core.windows.net/modula/inventory_events/`,
and Databricks reads that same path as a Unity Catalog **external location**.

### 3.1 Adapter → storage (already done by Bicep)
The Bicep `rbac` module gave `ca-datahub-adapter-dev` **Storage Blob Data Contributor**
on `stmodintdev`. Verify:

```bash
PRINCIPAL=$(az containerapp show -g $RG -n ca-datahub-adapter-dev --query identity.principalId -o tsv)
az role assignment list --assignee $PRINCIPAL --scope $(az storage account show -n $SA -g $RG --query id -o tsv) -o table
```

### 3.2 Databricks → storage (Unity Catalog plumbing)
1. **Create an Access Connector for Azure Databricks** (this is the managed identity
   Databricks uses to reach ADLS):
   ```bash
   az databricks access-connector create -g $RG -n dbac-modint-dev -l eastus2 \
     --identity-type SystemAssigned
   AC_PRINCIPAL=$(az databricks access-connector show -g $RG -n dbac-modint-dev --query identity.principalId -o tsv)
   az role assignment create --assignee $AC_PRINCIPAL \
     --role "Storage Blob Data Contributor" \
     --scope $(az storage account show -n $SA -g $RG --query id -o tsv)
   ```
2. In the Databricks **account console / workspace (Catalog → External Data)**:
   - **Storage credential**: New → Azure Managed Identity → paste the Access Connector
     resource ID (`az databricks access-connector show ... --query id -o tsv`).
     Name: `cred-modint-bronze`.
   - **External location**: New → name `loc-modula-bronze`,
     URL `abfss://bronze@stmodintdev.dfs.core.windows.net/`,
     credential `cred-modint-bronze` → Test connection → Create.
3. Grant your data engineering group rights on it:
   ```sql
   GRANT READ FILES, WRITE FILES ON EXTERNAL LOCATION `loc-modula-bronze` TO `data-engineers`;
   ```
4. Create the bronze table (or let DLT infer it):
   ```sql
   CREATE TABLE IF NOT EXISTS datahub.bronze.inventory_events
   USING JSON
   LOCATION 'abfss://bronze@stmodintdev.dfs.core.windows.net/modula/inventory_events/';
   ```
   For production, replace with a DLT pipeline using Auto Loader
   (`cloudFiles.format = json`) on that path, promoting to silver/gold.

> Note: if storage has public network access disabled (prod), the Databricks workspace
> must be VNet-injected or use a private endpoint route to `stmodintdev`; in dev the
> public endpoint works as deployed.

### 3.3 (Optional) Adapter → Databricks Jobs API
Only needed if the adapter triggers Databricks jobs (the default design lands files only).
If needed: workspace → Settings → Identity and access → add the adapter's managed identity
as a service principal, grant CAN_MANAGE_RUN on the ingest job, and the adapter
authenticates with `DefaultAzureCredential` against resource
`2ff814a6-3304-4ab8-85cb-cd0e6f879c1d` (the AzureDatabricks first-party app).

---

## Step 4 — Point Modula at APIM `POST /modula-adapter/v1/inventory/events`

### 4.1 Create the caller identity (Entra ID app for Modula/middleware)
```bash
CALLER=$(az ad sp create-for-rbac --name "sp-modula-caller-dev" --skip-assignment -o json)
CALLER_ID=$(echo $CALLER | jq -r .appId)
CALLER_SECRET=$(echo $CALLER | jq -r .password)
```
Expose/authorize it against the API app registration `api://modula-integration`
(the audience APIM validates): Entra ID → App registrations → the `modula-integration`
API app → **Expose an API** → ensure scope/role exists (e.g. app role
`inventory.publish`) → then on `sp-modula-caller-dev` → **API permissions** → add that
application permission → **Grant admin consent**.

### 4.2 Token acquisition (what Modula/middleware does)
```bash
curl -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=$CALLER_ID" \
  -d "client_secret=$CALLER_SECRET" \
  -d "scope=api://modula-integration/.default"
```
Cache the token until ~5 min before `expires_in`.

### 4.3 Configure Modula
- If Modula supports outbound webhooks (Modula WMS "Host interface"/event export):
  set URL `https://apim-modint-dev.azure-api.net/modula-adapter/v1/inventory/events`,
  method POST, header `Authorization: Bearer <token>`, content-type `application/json`,
  and map its export template to the CDM envelope.
- If it only supports file/DB/polled API export: run the poller mode of the inbound
  adapter (set `MODULA_POLL_ENABLED=true`, `MODULA_POLL_SECONDS=30` on
  `ca-modula-adapter-dev`); it uses `modula-base-url` + `modula-api-key` from Key Vault
  and publishes on Modula's behalf — nothing to configure in Modula beyond the API key.

### 4.4 Smoke test end to end
```bash
TOKEN=<token from 4.2>
curl -i -X POST "https://apim-modint-dev.azure-api.net/modula-adapter/v1/inventory/events" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d @cdm/sample-event.json     # use the example object from the CDM schema's examples[]
```
Expect `202` with partition/offset. Then confirm:
1. Event Hubs metrics: 1 incoming message on `inventory-events`.
2. `GET /modula-adapter/v1/inventory/events/{messageId}/status` → both targets DELIVERED.
3. D365: journal / on-hand change visible for the test item (use a test item id).
4. ADLS `bronze` container: a JSON file under `modula/inventory_events/eventType=Pick/...`.
5. App Insights: end-to-end transaction search on the `correlationId`.

### Troubleshooting quick hits
- `401` from APIM → token audience mismatch: scope must be `api://modula-integration/.default`.
- `403` publishing to Event Hub → Data Sender role assignment still propagating (RBAC can take ~5 min).
- `409` → you re-sent the same `messageId`; generate a fresh UUID per event.
- Nothing in D365 but bronze fills → check `dlq-d365` and `GET /processing/deadletters` (usually an unmapped item).
