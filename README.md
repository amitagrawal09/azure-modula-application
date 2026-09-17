# Modula ↔ D365 ↔ DataHub Integration

Event-driven, loosely coupled integration: Modula WMS inventory events flow through an
inbound adapter to Azure Event Hubs, fanned out to two independent consumers —
a D365 F&O adapter and a Databricks DataHub adapter — each on its own consumer group.

## Design principles
- **Loose coupling** — producers and consumers only share the CDM envelope
  (`cdm/inventory-event-cdm.schema.json`). Adding a new consumer = new consumer group +
  new adapter; nothing else changes.
- **Control message drives behavior** — `controlMessage.operation` (CREATE/UPDATE/DELETE/
  UPSERT/SNAPSHOT/REVERSAL) + `eventType` tell each consumer what to do; adapters never
  route on payload contents. `targetSystems` lets a message address D365 only, DataHub
  only, or ALL.
- **Ordering & idempotency** — `partitionKey` (warehouse+item) guarantees per-item
  ordering; `messageId` is the idempotency key; consumers checkpoint to ADLS.
- **Resilience** — retry with backoff in each consumer; poison messages escalate to
  Service Bus DLQs (`dlq-d365`, `dlq-datahub`) with a replay API. Event Hubs Capture
  archives everything to ADLS for backfill.
- **Observability** — `correlationId` propagated end-to-end into App Insights;
  KEDA scales consumers on Event Hub lag.
- **Zero secrets** — managed identities + RBAC everywhere; Key Vault only for
  external creds (Modula, D365 service principal).

## Repo contents
```
architecture-diagram.svg              High-level architecture
cdm/inventory-event-cdm.schema.json   CDM envelope (source of truth, registered in
                                      Event Hubs Schema Registry, Backward compat)
apis/modula-inbound-adapter.openapi.yaml
apis/d365-outbound-adapter.openapi.yaml
apis/datahub-outbound-adapter.openapi.yaml
iac/main.bicep + iac/modules/*        Full Azure environment (sub-scope deployment)
iac/deploy-apis.yaml                  GitHub Actions: Bicep + image build + APIM import
```

## Deploy
```bash
az deployment sub create -l eastus2 -f iac/main.bicep -p env=dev
# prod adds: Premium Event Hubs, zone redundancy, private endpoints, public access off
az deployment sub create -l eastus2 -f iac/main.bicep -p env=prod
```

## Post-deploy manual steps
1. Register CDM schema in the `inventory-cdm` schema group.
2. Store D365 service principal + Modula API creds in Key Vault.
3. Grant the DataHub adapter's identity access to the Databricks workspace /
   Unity Catalog external location for the bronze container.
4. Point Modula webhook (or middleware poller) at APIM `POST /modula-adapter/v1/inventory/events`.
