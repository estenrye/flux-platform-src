"""Warm Harbor's proxy-cache projects so builds keep working without the internet.

Harbor caches an upstream image the first time anything pulls it. This job pulls
every image in /config/images.txt (one `project/repository:tag` per line, `#`
comments allowed) through Harbor core as the read-only runner robot: the manifest
(for a multi-platform image, the linux/amd64 one) and every blob, discarding the
bytes. Layers already cached are served locally; new tags and new layers trigger
the upstream fetch.

It reports to Healthchecks (PING_URL, optional): success when every image
warmed, /fail with the list otherwise. Docker Hub rate limits are the usual
failure, see the bootstrap job's harbor-dockerhub Secret.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CORE = os.environ.get("HARBOR_CORE", "http://harbor-core.harbor.svc.cluster.local")
USER = os.environ.get("ROBOT_NAME", "robot$runner-pull")
SECRET = os.environ["ROBOT_SECRET"]
PLATFORM = ("linux", "amd64")
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])
BASIC = base64.b64encode(f"{USER}:{SECRET}".encode()).decode()


def request(url, headers=None, timeout=900):
    req = urllib.request.Request(url, headers=headers or {})
    return urllib.request.urlopen(req, timeout=timeout)


def token(repo):
    q = urllib.parse.urlencode({"service": "harbor-registry", "scope": f"repository:{repo}:pull"})
    with request(f"{CORE}/service/token?{q}", {"Authorization": f"Basic {BASIC}"}, 30) as r:
        return json.load(r)["token"]


def get_json(repo, ref, tok):
    with request(f"{CORE}/v2/{repo}/manifests/{ref}", {"Authorization": f"Bearer {tok}", "Accept": ACCEPT}, 900) as r:
        return json.load(r)


def drain(repo, digest, tok):
    n = 0
    with request(f"{CORE}/v2/{repo}/blobs/{digest}", {"Authorization": f"Bearer {tok}"}) as r:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                return n
            n += len(chunk)


def warm(image):
    repo, _, tag = image.rpartition(":")
    tok = token(repo)
    m = get_json(repo, tag, tok)
    if "manifests" in m:
        pick = next(
            (x for x in m["manifests"]
             if x.get("platform", {}).get("os") == PLATFORM[0] and x.get("platform", {}).get("architecture") == PLATFORM[1]),
            None,
        )
        if pick is None:
            raise RuntimeError("no linux/amd64 manifest")
        m = get_json(repo, pick["digest"], tok)
    total = 0
    for d in [m["config"]["digest"]] + [l["digest"] for l in m["layers"]]:
        total += drain(repo, d, tok)
    return total


def ping(url, ok, body):
    if not url:
        return
    for _ in range(3):
        try:
            req = urllib.request.Request(url if ok else url + "/fail", data=body.encode()[:10000], method="POST")
            with urllib.request.urlopen(req, timeout=15) as r:
                r.read()
            return
        except (urllib.error.URLError, OSError) as exc:
            print(f"ping failed: {exc}", file=sys.stderr)
            time.sleep(5)


def main():
    images = []
    for line in open("/config/images.txt"):
        line = line.split("#", 1)[0].strip()
        if line:
            images.append(line)
    failed, lines = [], []
    for image in images:
        t = time.time()
        try:
            n = warm(image)
            msg = f"OK   {image} {n / 1e6:.0f} MB in {time.time() - t:.0f}s"
        except Exception as exc:  # report every image, not just the first failure
            failed.append(image)
            msg = f"FAIL {image}: {exc}"
        print(msg, flush=True)
        lines.append(msg)
    summary = f"{len(images) - len(failed)}/{len(images)} images warmed\n" + "\n".join(lines)
    ping(os.environ.get("PING_URL", ""), not failed, summary)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
