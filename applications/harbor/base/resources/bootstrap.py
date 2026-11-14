"""Idempotent Harbor bootstrap: registry endpoints, proxy-cache projects and the
read-only robot account the CI runners pull with (docs/adr/0031).

Harbor has no declarative objects, so this reconciles through the API as the
local admin. Run by the CronJob harbor-bootstrap (daily; also create a Job from
it after changing this file).
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("HARBOR_URL", "http://harbor-core.harbor.svc.cluster.local") + "/api/v2.0"
AUTH = "Basic " + base64.b64encode(("admin:" + os.environ["HARBOR_ADMIN_PASSWORD"]).encode()).decode()
ROBOT_SECRET = os.environ["ROBOT_SECRET"]

# project name -> (registry endpoint name, type, url)
UPSTREAMS = {
    "dockerhub": ("dockerhub", "docker-hub", "https://hub.docker.com"),
    "gitea": ("gitea-images", "docker-registry", "https://docker.gitea.com"),
    "ghcr": ("ghcr", "github-ghcr", "https://ghcr.io"),
    "quay": ("quay", "quay", "https://quay.io"),
}
ROBOT_NAME = "runner-pull"  # Harbor prefixes it: robot$runner-pull


def call(method, path, body=None, ok=(200, 201, 204)):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Authorization": AUTH, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None), r.headers
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        if e.code in ok:
            return e.code, None, e.headers
        raise SystemExit("%s %s -> %s %s" % (method, path, e.code, raw[:300]))


def wait_ready():
    for _ in range(30):
        try:
            if call("GET", "/ping")[0] == 200:
                return
        except SystemExit:
            pass
        except OSError:
            pass
        time.sleep(10)
    raise SystemExit("Harbor core did not become ready")


def registries():
    _, d, _ = call("GET", "/registries?page_size=100")
    return {r["name"]: r for r in d}


def ensure_registry(name, rtype, url):
    existing = registries().get(name)
    cred = {}
    if name == "dockerhub" and os.environ.get("DOCKERHUB_USERNAME") and os.environ.get("DOCKERHUB_TOKEN"):
        cred = {"credential": {"type": "basic", "access_key": os.environ["DOCKERHUB_USERNAME"],
                               "access_secret": os.environ["DOCKERHUB_TOKEN"]}}
    body = {"name": name, "type": rtype, "url": url, "insecure": False, **cred}
    if existing is None:
        call("POST", "/registries", body)
        print("created registry", name)
    else:
        if existing["url"] != url or existing["type"] != rtype or cred:
            call("PUT", "/registries/%d" % existing["id"], body)
            print("updated registry", name)
    return registries()[name]["id"]


def ensure_project(project, registry_id):
    status, _, _ = call("HEAD", "/projects?project_name=" + project, ok=(200, 404))
    if status == 200:
        return
    call("POST", "/projects", {"project_name": project, "public": False, "registry_id": registry_id,
                                "metadata": {"public": "false"}})
    print("created proxy-cache project", project)


def ensure_robot():
    perms = [{"kind": "project", "namespace": p,
              "access": [{"resource": "repository", "action": "pull"}]} for p in UPSTREAMS]
    _, robots, _ = call("GET", "/robots?page_size=100&q=Level%3Dsystem")
    full = "robot$" + ROBOT_NAME
    cur = next((r for r in robots or [] if r["name"] == full), None)
    if cur is None:
        call("POST", "/robots", {"name": ROBOT_NAME, "level": "system", "duration": -1,
                                 "description": "CI runners: pull through the proxy-cache projects",
                                 "secret": ROBOT_SECRET, "permissions": perms})
        print("created robot", full)
        return
    call("PUT", "/robots/%d" % cur["id"], {"name": full, "level": "system", "duration": -1, "disable": False,
                                           "description": cur.get("description", ""), "permissions": perms})
    call("PATCH", "/robots/%d" % cur["id"], {"secret": ROBOT_SECRET})
    print("reconciled robot", full)


def main():
    wait_ready()
    for project, (reg, rtype, url) in UPSTREAMS.items():
        ensure_project(project, ensure_registry(reg, rtype, url))
    ensure_robot()
    print("done")


if __name__ == "__main__":
    sys.exit(main())
