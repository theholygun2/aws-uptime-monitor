import json
import math
import os
import socket
import ssl
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

TIMEOUT_SECONDS = 5
NAMESPACE = os.environ.get("NAMESPACE", "ServerMonitor")
TARGETS = json.loads(os.environ.get("TARGETS", "[]"))
TABLE_NAME = os.environ.get("TABLE_NAME", "")
BUCKET_NAME = os.environ.get("BUCKET_NAME", "")
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "7"))
WINDOW_HOURS = int(os.environ.get("AVAILABILITY_WINDOW_HOURS", "24"))

cloudwatch = boto3.client("cloudwatch")
s3 = boto3.client("s3")


def get_table():
    return boto3.resource("dynamodb").Table(TABLE_NAME)


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
def check_target(target):
    """Make one HTTP request and return a result dict."""
    name = target["name"]
    url = target["url"]
    expected = target.get("expected_status", 200)

    start = time.monotonic()
    status = None
    error = None

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "server-monitor/1.0"})
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            status = resp.status
    except urllib.error.HTTPError as e:
        # Server answered with 4xx/5xx. Still a valid response, compare below.
        status = e.code
    except urllib.error.URLError as e:
        reason = e.reason
        if isinstance(reason, socket.gaierror):
            error = "dns_failure"
        elif isinstance(reason, ssl.SSLError):
            error = "tls_failure"
        elif isinstance(reason, (socket.timeout, TimeoutError)):
            error = "timeout"
        else:
            error = f"connection_error: {reason}"
    except (socket.timeout, TimeoutError):
        error = "timeout"
    except Exception as e:  # noqa: BLE001
        error = f"unexpected: {e}"

    elapsed_ms = round((time.monotonic() - start) * 1000, 1)
    up = 1 if (error is None and status == expected) else 0

    return {
        "name": name,
        "url": url,
        "up": up,
        "status": status,
        "error": error,
        "response_ms": elapsed_ms,
    }


# ---------------------------------------------------------------------------
# CloudWatch metrics (alerting path)
# ---------------------------------------------------------------------------
def publish_metrics(results):
    metric_data = []
    for r in results:
        dims = [{"Name": "Target", "Value": r["name"]}]
        metric_data.append(
            {"MetricName": "Up", "Dimensions": dims, "Value": r["up"], "Unit": "Count"}
        )
        # Only record latency when we actually got a response
        if r["error"] is None:
            metric_data.append(
                {
                    "MetricName": "ResponseTimeMs",
                    "Dimensions": dims,
                    "Value": r["response_ms"],
                    "Unit": "Milliseconds",
                }
            )

    # Heartbeat: proves the monitor itself is running (no dimensions)
    metric_data.append({"MetricName": "Heartbeat", "Value": 1, "Unit": "Count"})

    cloudwatch.put_metric_data(Namespace=NAMESPACE, MetricData=metric_data)


# ---------------------------------------------------------------------------
# DynamoDB history
# ---------------------------------------------------------------------------
def load_history(table, name, since_ts):
    """Return [{'up': int, 'response_ms': float}] for one target since since_ts."""
    rows = []
    kwargs = {
        "KeyConditionExpression": Key("target").eq(name) & Key("ts").gte(since_ts),
        "ProjectionExpression": "#u, #r",
        "ExpressionAttributeNames": {"#u": "up", "#r": "response_ms"},
    }
    while True:
        resp = table.query(**kwargs)
        for item in resp["Items"]:
            rows.append(
                {"up": int(item["up"]), "response_ms": float(item["response_ms"])}
            )
        if "LastEvaluatedKey" not in resp:
            break
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return rows


def save_result(table, r, now):
    item = {
        "target": r["name"],
        "ts": now,
        "up": r["up"],
        "response_ms": Decimal(str(r["response_ms"])),
        "expires_at": now + RETENTION_DAYS * 86400,
    }
    if r["status"] is not None:
        item["status"] = r["status"]
    if r["error"]:
        item["error"] = r["error"]
    table.put_item(Item=item)


# ---------------------------------------------------------------------------
# Availability (SLI) and status.json
# ---------------------------------------------------------------------------
def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(pct / 100 * len(ordered)) - 1)
    return ordered[index]


def summarize(r, history, checked_at):
    """Combine past rows with the current result into one status entry."""
    rows = history + [{"up": r["up"], "response_ms": r["response_ms"]}]
    total = len(rows)
    ups = sum(row["up"] for row in rows)
    latencies = [row["response_ms"] for row in rows if row["up"] == 1]

    return {
        "name": r["name"],
        "status": "up" if r["up"] else "down",
        "availability_pct": round(ups / total * 100, 3),
        "checks_in_window": total,
        "failed_checks_in_window": total - ups,
        "response_ms": r["response_ms"],
        "avg_response_ms": round(sum(latencies) / len(latencies), 1) if latencies else None,
        "p95_response_ms": round(percentile(latencies, 95), 1) if latencies else None,
        "last_error": r["error"],
        "last_checked": checked_at,
    }


def overall_status(entries):
    down = sum(1 for e in entries if e["status"] == "down")
    if down == 0:
        return "operational"
    if down == len(entries):
        return "major_outage"
    return "partial_outage"


def write_status_json(entries, checked_at):
    body = {
        "generated_at": checked_at,
        "overall": overall_status(entries),
        "window_hours": WINDOW_HOURS,
        "targets": entries,
    }
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key="status.json",
        Body=json.dumps(body).encode("utf-8"),
        ContentType="application/json",
        CacheControl="max-age=30",
    )


# ---------------------------------------------------------------------------
# Lambda entry point
# ---------------------------------------------------------------------------
def handler(event, context):
    if not TARGETS:
        print("No targets configured")
        return {"checked": 0}

    now = int(time.time())
    checked_at = datetime.fromtimestamp(now, tz=timezone.utc).isoformat()

    with ThreadPoolExecutor(max_workers=len(TARGETS)) as pool:
        results = list(pool.map(check_target, TARGETS))

    for r in results:
        print(json.dumps(r))

    # 1) Alerting path first: this must never be blocked by storage problems.
    publish_metrics(results)

    # 2) History + status page. Errors are logged but do not break alerting.
    try:
        table = get_table()
        since = now - WINDOW_HOURS * 3600
        entries = []
        for r in results:
            history = load_history(table, r["name"], since)  # before saving this check
            save_result(table, r, now)
            entries.append(summarize(r, history, checked_at))
        write_status_json(entries, checked_at)
    except Exception as e:  # noqa: BLE001
        print(f"STORAGE_ERROR: {e}")

    return {"checked": len(results), "down": [r["name"] for r in results if not r["up"]]}


if __name__ == "__main__":
    # Local quick test of HTTP checks only:
    # TARGETS='[{"name":"x","url":"https://example.com"}]' python checker.py
    for t in TARGETS:
        print(check_target(t))
