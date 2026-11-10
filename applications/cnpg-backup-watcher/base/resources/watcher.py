"""Report CloudNativePG backup health to Healthchecks.

For every target database: find the newest completed Backup, check that the
latest Backup did not fail, and check the Cluster's ContinuousArchiving
condition (WAL archiving). Healthy -> ping the database's check; any problem ->
ping its /fail endpoint with the reasons. Silence past the check's period+grace
alerts on its own, which also covers this job or the cluster being down.

Read-only against the Kubernetes API. Stdlib only.

The Cluster's status.lastSuccessfulBackup is empty with the barman-cloud
plugin, so the Backup objects are the source of truth.
"""

import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
MAX_AGE = timedelta(hours=float(os.environ.get("MAX_BACKUP_AGE_HOURS", "26")))
TARGETS = json.loads(os.environ["TARGETS"])


def api_get(path):
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ["KUBERNETES_SERVICE_PORT"]
    if ":" in host:  # IPv6 literal
        host = f"[{host}]"
    with open(f"{SA}/token") as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    req = urllib.request.Request(
        f"https://{host}:{port}{path}", headers={"Authorization": f"Bearer {token}"}
    )
    with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
        return json.load(resp)


def ts(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def evaluate(target, backups, clusters, now):
    """Return (problems, info) for one database."""
    ns, name = target["namespace"], target["cluster"]
    problems, info = [], []

    mine = [
        b
        for b in backups
        if b["metadata"]["namespace"] == ns
        and b.get("spec", {}).get("cluster", {}).get("name") == name
    ]
    done = [
        b
        for b in mine
        if b.get("status", {}).get("phase") == "completed"
        and b["status"].get("stoppedAt")
    ]
    if not done:
        problems.append("no completed backup found")
    else:
        newest = max(done, key=lambda b: ts(b["status"]["stoppedAt"]))
        age = now - ts(newest["status"]["stoppedAt"])
        hours = age.total_seconds() / 3600
        info.append(f"newest completed backup {newest['metadata']['name']} is {hours:.1f}h old")
        if age > MAX_AGE:
            problems.append(
                f"newest completed backup {newest['metadata']['name']} is {hours:.1f}h old "
                f"(limit {MAX_AGE.total_seconds() / 3600:.0f}h)"
            )

    if mine:
        latest = max(mine, key=lambda b: b["metadata"]["creationTimestamp"])
        phase = latest.get("status", {}).get("phase")
        if phase == "failed":
            err = str(latest["status"].get("error", ""))[:300]
            problems.append(f"latest backup {latest['metadata']['name']} failed: {err}")

    cluster = next(
        (
            c
            for c in clusters
            if c["metadata"]["namespace"] == ns and c["metadata"]["name"] == name
        ),
        None,
    )
    if cluster is None:
        problems.append("Cluster object not found")
    else:
        conds = {c["type"]: c for c in cluster.get("status", {}).get("conditions", [])}
        arch = conds.get("ContinuousArchiving")
        if not arch or arch.get("status") != "True":
            msg = (arch or {}).get("message", "condition missing")
            problems.append(f"ContinuousArchiving is not True: {msg}"[:300])
        else:
            info.append("WAL archiving OK")
    return problems, info


def ping(url, body):
    last = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, data=body.encode(), method="POST")
            with urllib.request.urlopen(req, timeout=15) as resp:
                resp.read()
            return True
        except (urllib.error.URLError, OSError) as exc:
            last = exc
            time.sleep(5)
    print(f"ping failed after retries: {last}", file=sys.stderr)
    return False


def main():
    now = datetime.now(timezone.utc)
    backups = api_get("/apis/postgresql.cnpg.io/v1/backups")["items"]
    clusters = api_get("/apis/postgresql.cnpg.io/v1/clusters")["items"]

    failed_pings = 0
    for target in TARGETS:
        label = f"{target['namespace']}/{target['cluster']}"
        url = os.environ[target["ping_env"]]
        problems, info = evaluate(target, backups, clusters, now)
        if problems:
            body = f"{label}: " + "; ".join(problems)
            print(f"PROBLEM {body}")
            ok = ping(url + "/fail", body)
        else:
            body = f"{label}: " + "; ".join(info)
            print(f"OK {body}")
            ok = ping(url, body)
        if not ok:
            failed_pings += 1

    # A detected problem is reported via /fail and is not a Job failure; only
    # being unable to report (or to read the API, which raises) fails the Job.
    return 1 if failed_pings else 0


if __name__ == "__main__":
    sys.exit(main())
