#!/usr/bin/env python3
"""
Modula WMS Simulator
Generates realistic CDM inventory events (Pick, PutAway, InventoryAdjustment,
CycleCount, StockOnHandSnapshot) and delivers them like Modula would:

  MODE=api       POST to the Modula Inbound Adapter via APIM with an Entra ID token
  MODE=dry-run   Print events to stdout (validate shapes, no network)

Config via environment variables (all optional except MODE=api endpoint/auth):
  TARGET_URL        e.g. https://apim-modint-dev.azure-api.net/modula-adapter/v1/inventory/events
  TENANT_ID, CLIENT_ID, CLIENT_SECRET   caller app (sp-modula-caller-dev)
  SCOPE             default api://modula-integration/.default
  RATE_PER_MIN      events per minute (default 12)
  DURATION_SEC      how long to run (default 300; 0 = forever)
  BATCH_SIZE        >1 uses the /batch endpoint (default 1)
  WAREHOUSE_ID      default WH01
  TENANT            controlMessage.tenant (default TFFI)
  SEED              RNG seed for reproducible runs
  ERROR_RATE        fraction of events made intentionally invalid (default 0.0)
                    to exercise 400 handling / quarantine
  UNMAPPED_RATE     fraction using an item id not in D365 (default 0.0)
                    to exercise the DLQ path
"""
import json, os, random, sys, time, uuid, datetime, urllib.request, urllib.error

MODE = os.environ.get("MODE", "dry-run")
TARGET_URL = os.environ.get("TARGET_URL", "")
TENANT_ID = os.environ.get("TENANT_ID", "")
CLIENT_ID = os.environ.get("CLIENT_ID", "")
CLIENT_SECRET = os.environ.get("CLIENT_SECRET", "")
SCOPE = os.environ.get("SCOPE", "api://modula-integration/.default")
RATE = float(os.environ.get("RATE_PER_MIN", "12"))
DURATION = int(os.environ.get("DURATION_SEC", "300"))
BATCH = int(os.environ.get("BATCH_SIZE", "1"))
WAREHOUSE = os.environ.get("WAREHOUSE_ID", "WH01")
TENANT = os.environ.get("TENANT", "TFFI")
ERROR_RATE = float(os.environ.get("ERROR_RATE", "0.0"))
UNMAPPED_RATE = float(os.environ.get("UNMAPPED_RATE", "0.0"))
if os.environ.get("SEED"):
    random.seed(int(os.environ["SEED"]))

VLMS = ["VLM-01", "VLM-02", "VLM-03", "VLM-04"]
OPERATORS = ["jdoe", "mgarcia", "tchen", "kpatel", "rsmith"]
ITEMS = [
    ("ITEM-10045", "Stainless bracket 40mm", "EA"),
    ("ITEM-10046", "Hex bolt M8x25", "EA"),
    ("ITEM-10102", "Bearing 6204-2RS", "EA"),
    ("ITEM-10231", "Gasket kit A7", "EA"),
    ("ITEM-20011", "Food-grade lubricant", "EA"),
    ("ITEM-20087", "Label roll 4x6", "CS"),
    ("ITEM-30055", "Sensor assembly QX", "EA"),
    ("ITEM-30099", "Drive belt 1120mm", "EA"),
]
REASONS = ["DAMAGE", "SHRINK", "FOUND", "RECOUNT", "EXPIRED"]

_token = {"value": None, "exp": 0}

def token():
    if _token["value"] and time.time() < _token["exp"] - 300:
        return _token["value"]
    data = (f"grant_type=client_credentials&client_id={CLIENT_ID}"
            f"&client_secret={CLIENT_SECRET}&scope={SCOPE}").encode()
    req = urllib.request.Request(
        f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token",
        data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
    body = json.loads(urllib.request.urlopen(req, timeout=30).read())
    _token["value"] = body["access_token"]
    _token["exp"] = time.time() + int(body.get("expires_in", 3600))
    return _token["value"]

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")

def location():
    return {"locationId": random.choice(VLMS),
            "trayId": f"T-{random.randint(1,60)}",
            "cellId": f"C-{random.randint(100,399)}"}

def base_line(n, item, qty, ttype):
    item_id, desc, uom = item
    if random.random() < UNMAPPED_RATE:
        item_id = f"ITEM-UNMAPPED-{random.randint(1,99)}"
    line = {"lineNumber": n, "itemId": item_id, "itemDescription": desc,
            "quantity": qty, "unitOfMeasure": uom, "transactionType": ttype}
    if random.random() < 0.4:
        line["tracking"] = {"batchNumber": f"B{datetime.date.today():%Y%m%d}{random.randint(1,9)}"}
    return line

def make_event():
    kind = random.choices(
        ["Pick", "PutAway", "InventoryAdjustment", "CycleCount", "StockOnHandSnapshot"],
        weights=[45, 30, 10, 10, 5])[0]
    item = random.choice(ITEMS)
    lines, ref, op = [], None, "CREATE"

    if kind == "Pick":
        qty = -random.randint(1, 24)
        l = base_line(1, item, qty, "ISSUE"); l["fromLocation"] = location()
        lines = [l]
        ref = {"documentType": "SalesOrder",
               "documentNumber": f"SO-{random.randint(1000,9999):06d}",
               "documentLine": random.randint(1, 8)}
    elif kind == "PutAway":
        qty = random.randint(1, 48)
        l = base_line(1, item, qty, "RECEIPT"); l["toLocation"] = location()
        lines = [l]
        ref = {"documentType": "PurchaseOrder",
               "documentNumber": f"PO-{random.randint(1000,9999):06d}",
               "documentLine": random.randint(1, 5)}
    elif kind == "InventoryAdjustment":
        sign = random.choice([1, -1]); qty = sign * random.randint(1, 6)
        l = base_line(1, item, qty, "ADJUSTMENT_IN" if sign > 0 else "ADJUSTMENT_OUT")
        l["fromLocation" if sign < 0 else "toLocation"] = location()
        l["reasonCode"] = random.choice(REASONS)
        lines = [l]
        ref = {"documentType": "AdjustmentJournal", "documentNumber": f"ADJ-{random.randint(100,999)}"}
    elif kind == "CycleCount":
        expected = random.randint(10, 200)
        counted = expected + random.choice([0, 0, 0, -2, -1, 1, 2])
        l = base_line(1, item, counted - expected, "COUNT")
        l["countedQuantity"], l["expectedQuantity"] = counted, expected
        l["fromLocation"] = location()
        if counted != expected:
            l["reasonCode"] = "RECOUNT"
        lines = [l]
        ref = {"documentType": "CountingJournal", "documentNumber": f"CNT-{random.randint(100,999)}"}
        op = "UPSERT"
    else:  # StockOnHandSnapshot
        lines = []
        for i, it in enumerate(random.sample(ITEMS, k=3), start=1):
            l = base_line(i, it, random.randint(0, 300), "COUNT")
            l["fromLocation"] = location()
            lines.append(l)
        op = "SNAPSHOT"

    env = {
        "controlMessage": {
            "messageId": str(uuid.uuid4()),
            "correlationId": str(uuid.uuid4()),
            "eventType": kind,
            "operation": op,
            "sourceSystem": "MODULA",
            "targetSystems": ["ALL"],
            "schemaVersion": "1.0.0",
            "eventTimestamp": now(),
            "partitionKey": f"{WAREHOUSE}-{lines[0]['itemId']}" if lines else WAREHOUSE,
            "tenant": TENANT,
        },
        "payload": {
            "warehouseId": WAREHOUSE,
            "vlmUnitId": random.choice(VLMS),
            "operator": random.choice(OPERATORS),
            "lines": lines,
        },
    }
    if ref:
        env["payload"]["referenceDocument"] = ref
    if random.random() < ERROR_RATE:  # intentionally break it
        del env["controlMessage"]["eventType"]
    return env

def post(events):
    url = TARGET_URL if len(events) == 1 else TARGET_URL.rstrip("/") + "/batch"
    body = json.dumps(events[0] if len(events) == 1 else events).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token()}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()[:200]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]
    except Exception as e:
        return -1, str(e)

def main():
    if MODE == "api" and not (TARGET_URL and TENANT_ID and CLIENT_ID and CLIENT_SECRET):
        sys.exit("MODE=api requires TARGET_URL, TENANT_ID, CLIENT_ID, CLIENT_SECRET")
    interval = 60.0 / RATE
    start, sent = time.time(), 0
    print(f"[simulator] mode={MODE} rate={RATE}/min batch={BATCH} "
          f"duration={'forever' if DURATION == 0 else str(DURATION)+'s'} warehouse={WAREHOUSE}")
    while DURATION == 0 or time.time() - start < DURATION:
        events = [make_event() for _ in range(BATCH)]
        if MODE == "api":
            code, resp = post(events)
            ok = "OK " if code in (200, 202) else "ERR"
            print(f"[{ok}] {code} {events[0]['controlMessage'].get('eventType','?'):22s} "
                  f"msg={events[0]['controlMessage']['messageId'][:8]} {resp[:80]}")
        else:
            print(json.dumps(events[0] if BATCH == 1 else events, indent=2))
        sent += len(events)
        time.sleep(interval * BATCH)
    print(f"[simulator] done — {sent} events in {int(time.time()-start)}s")

if __name__ == "__main__":
    main()
