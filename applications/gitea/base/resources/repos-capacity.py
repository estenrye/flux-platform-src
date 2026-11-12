"""Report the utilisation and snapshot freshness of Gitea's repository volume to Healthchecks.

The volume is the NFS PV gitea-repos, mounted read-only at MOUNT. Its size is
the dataset's refquota (pcd-ce-deploy tofu-truenas), which NFS clients see as
the filesystem size. At or above THRESHOLD_PERCENT the check is pinged on its
/fail endpoint, otherwise on the plain URL. Silence past the check's period and
grace also alerts, which covers this job or the mount being down (a hung NFS
mount leaves the pod in ContainerCreating and no ping is sent).

If the reported size is more than 10% over EXPECTED_SIZE_GIB the quota is not
applied (the percentage would be meaningless), and that is reported as a failure.

Second check (PING_URL_SNAPSHOTS, optional): the newest ZFS snapshot of the
dataset, listed from MOUNT/.zfs/snapshot (the directory's mtime is the snapshot
creation time), must be younger than MAX_SNAPSHOT_AGE_HOURS. The daily snapshot
task takes a snapshot even when nothing changed, so a gap is a real failure; the
hourly ones are skipped on an idle dataset and are not checked.
Stdlib only.
"""

import os
import shutil
import sys
import time
import urllib.error
import urllib.request

GIB = 1024**3


def evaluate(total, used, threshold, expected_gib):
    """Return (ok, message)."""
    if total <= 0:
        return False, "volume reports size 0"
    pct = used * 100 / total
    summary = f"gitea-repos {pct:.1f}% used ({used / GIB:.1f} of {total / GIB:.1f} GiB)"
    if total > expected_gib * GIB * 1.1:
        return False, f"{summary}; size exceeds the expected {expected_gib} GiB, so the dataset quota is not applied"
    if pct >= threshold:
        return False, f"{summary}; at or above {threshold}%"
    return True, summary


def evaluate_snapshots(mtimes, now, max_age_hours):
    """Return (ok, message) from snapshot creation times (epoch seconds)."""
    if not mtimes:
        return False, "no ZFS snapshots found under .zfs/snapshot"
    newest = max(mtimes)
    age_h = (now - newest) / 3600
    summary = f"{len(mtimes)} snapshots, newest {age_h:.1f}h old"
    if age_h > max_age_hours:
        return False, f"{summary}; older than {max_age_hours:g}h"
    return True, summary


def snapshot_mtimes(mount):
    snapdir = os.path.join(mount, ".zfs", "snapshot")
    return [e.stat().st_mtime for e in os.scandir(snapdir) if e.is_dir()]


def ping(url, body):
    last = None
    for _ in range(3):
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


def report(url, ok, message):
    print(("OK " if ok else "PROBLEM ") + message)
    return ping(url if ok else url + "/fail", message)


def main():
    mount = os.environ.get("MOUNT", "/repos")
    usage = shutil.disk_usage(mount)
    ok, message = evaluate(
        usage.total,
        usage.used,
        float(os.environ.get("THRESHOLD_PERCENT", "75")),
        float(os.environ.get("EXPECTED_SIZE_GIB", "50")),
    )
    sent = report(os.environ["PING_URL"], ok, message)

    snap_url = os.environ.get("PING_URL_SNAPSHOTS")
    if snap_url:
        try:
            ok, message = evaluate_snapshots(
                snapshot_mtimes(mount), time.time(), float(os.environ.get("MAX_SNAPSHOT_AGE_HOURS", "26"))
            )
        except OSError as exc:
            ok, message = False, f"cannot read {mount}/.zfs/snapshot: {exc}"
        sent = report(snap_url, ok, "gitea-repos snapshots: " + message) and sent
    sys.exit(0 if sent else 1)


if __name__ == "__main__":
    main()
