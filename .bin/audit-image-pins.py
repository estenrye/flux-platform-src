#!/usr/bin/env python3
"""Audit kustomize `images:` entries that are pinned by digest alone.

Renovate follows an `images:` entry that has a digest but no `newTag` as the
digest of the image's `latest` tag, independently of the Helm chart that
deploys it. That already moved the OpenTelemetry operator ahead of its chart
(#40) and Grafana and its sidecar onto `latest` (#218, #225). Adding `newTag`
makes Renovate track the image by version instead.

For every such entry this tool
  1. renders the kustomization with its `images:` block removed, to see which
     tag the chart or manifests actually ship,
  2. looks up that tag's current digest in the registry, and
  3. compares it with the pinned digest.

Classification
  MATCH      the pinned digest is the shipped tag's digest: adding `newTag` is a
             no-op for what runs, and is the only thing --apply changes.
  DRIFT      the pinned digest is some other image (typically `latest`, or an
             older/newer release). Adding the shipped tag would change what runs,
             so it is only reported.
  AMBIGUOUS  several different tags are shipped for the image.
  NOTAG      the image is not found in the render, or has no tag there.
  RENDERFAIL kustomize could not render the app.

Usage (from the repository root; needs kustomize, helm and docker buildx):
  .bin/audit-image-pins.py                       # audit every application
  .bin/audit-image-pins.py applications/grafana  # only matching paths
  .bin/audit-image-pins.py --apply               # also add newTag for MATCH entries
  .bin/audit-image-pins.py --json report.json
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
KUSTOMIZE = ["kustomize", "build", "--enable-helm", "--helm-kube-version", "1.36.2"]
_digest_cache = {}


def find_images_block(lines):
    """Return (start, end) line indexes of the top-level `images:` block, or None."""
    for i, line in enumerate(lines):
        if re.match(r"^images:\s*(#.*)?$", line):
            j = i + 1
            while j < len(lines):
                l = lines[j]
                if l.strip() == "" or l[0] in " \t-#":
                    j += 1
                    continue
                break
            return i, j
    return None


def parse_entries(lines, start, end):
    """Entries as dicts with name/digest/newTag/newName and the line index of each key."""
    entries, cur = [], None
    for k in range(start + 1, end):
        l = lines[k]
        m = re.match(r"^(\s*)-\s+(\w+):\s*(.*?)\s*$", l)
        if m:
            cur = {"indent": m.group(1), "_line": {}}
            entries.append(cur)
            key, val = m.group(2), m.group(3)
            cur[key] = val.strip("\"'")
            cur["_line"][key] = k
            continue
        m = re.match(r"^(\s+)(\w+):\s*(.*?)\s*$", l)
        if m and cur is not None and not l.lstrip().startswith("#"):
            cur[m.group(2)] = m.group(3).strip("\"'")
            cur["_line"][m.group(2)] = k
    return entries


def yaml_tag(tag):
    """Quote a tag that YAML would read as a number or boolean (e.g. 0.2, 3, yes):
    kustomize requires newTag to be a string."""
    if re.fullmatch(r"[0-9_]+(\.[0-9_]*)?|\.[0-9_]+", tag) or tag.lower() in ("true", "false", "null", "yes", "no", "on", "off", "~"):
        return f'"{tag}"'
    return tag


def registry_digest(ref):
    if ref in _digest_cache:
        return _digest_cache[ref]
    r = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", ref, "--format", "{{.Manifest.Digest}}"],
        capture_output=True, text=True,
    )
    d = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else None
    _digest_cache[ref] = d
    return d


def shipped_tags(rendered, name):
    pat = re.compile(re.escape(name) + r"(?::([A-Za-z0-9][A-Za-z0-9._\-]*))?(?:@sha256:[0-9a-f]{64})?(?![A-Za-z0-9._/\-])")
    tags, seen = set(), False
    for m in pat.finditer(rendered):
        # require the match to start a reference, not sit inside a longer path
        start = m.start()
        if start > 0 and re.match(r"[A-Za-z0-9._/\-]", rendered[start - 1]):
            continue
        seen = True
        if m.group(1):
            tags.add(m.group(1))
    return seen, tags


def audit_file(path, apply):
    text = path.read_text()
    lines = text.splitlines(keepends=True)
    blk = find_images_block([l.rstrip("\n") for l in lines])
    if not blk:
        return []
    entries = [e for e in parse_entries([l.rstrip("\n") for l in lines], *blk)
               if e.get("name") and e.get("digest") and not e.get("newTag") and not e.get("newName")]
    if not entries:
        return []
    stripped = "".join(lines[: blk[0]] + lines[blk[1]:])
    rel = str(path.relative_to(ROOT).parent)
    try:
        path.write_text(stripped)
        r = subprocess.run(KUSTOMIZE + [str(path.parent)], capture_output=True, text=True)
    finally:
        path.write_text(text)
    results = []
    if r.returncode != 0:
        for e in entries:
            results.append({"app": rel, "image": e["name"], "pinned": e["digest"], "status": "RENDERFAIL",
                            "detail": r.stderr.strip().splitlines()[-1][:120] if r.stderr.strip() else ""})
        return results
    to_apply = []
    for e in entries:
        seen, tags = shipped_tags(r.stdout, e["name"])
        res = {"app": rel, "image": e["name"], "pinned": e["digest"]}
        if not seen or not tags:
            res.update(status="NOTAG", detail="not found in the render" if not seen else "no tag in the render")
        elif len(tags) > 1:
            res.update(status="AMBIGUOUS", detail="tags: " + ", ".join(sorted(tags)))
        else:
            tag = next(iter(tags))
            shipped = registry_digest(f"{e['name']}:{tag}")
            latest = registry_digest(f"{e['name']}:latest")
            res["tag"] = tag
            res["shipped_digest"] = shipped
            if shipped is None:
                res.update(status="NOTAG", detail=f"could not resolve {tag} in the registry")
            elif shipped == e["digest"]:
                res["status"] = "MATCH"
                to_apply.append((e, tag))
            else:
                res.update(status="DRIFT", detail="pinned digest is the digest of `latest`" if latest == e["digest"]
                           else "pinned digest is not the shipped tag's (and not latest)")
        results.append(res)
    if apply and to_apply:
        new = list(lines)
        # insert from the bottom up so earlier indexes stay valid
        for e, tag in sorted(to_apply, key=lambda x: -x[0]["_line"]["digest"]):
            dl = e["_line"]["digest"]
            ind = re.match(r"^(\s*)", lines[dl]).group(1)
            new.insert(dl, f"{ind}newTag: {yaml_tag(tag)}\n")
        path.write_text("".join(new))
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", help="only kustomizations whose path contains one of these")
    ap.add_argument("--apply", action="store_true", help="add newTag to MATCH entries")
    ap.add_argument("--json", help="also write the results to this file")
    a = ap.parse_args()
    files = subprocess.run(["git", "ls-files", "applications/**/kustomization.yaml", "clusters/**/kustomization.yaml"],
                           cwd=ROOT, capture_output=True, text=True).stdout.split()
    results = []
    for f in files:
        if a.paths and not any(p in f for p in a.paths):
            continue
        try:
            res = audit_file(ROOT / f, a.apply)
        except Exception as ex:  # keep going; report the file
            res = [{"app": f, "image": "?", "pinned": "", "status": "RENDERFAIL", "detail": str(ex)[:120]}]
        for r in res:
            print(f"{r['status']:10} {r['app']:50} {r['image'][:58]:58} {r.get('tag', ''):14} {r.get('detail', '')}", flush=True)
        results.extend(res)
    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print("\nsummary:", ", ".join(f"{k}={v}" for k, v in sorted(counts.items())), flush=True)
    if a.json:
        pathlib.Path(a.json).write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    sys.exit(main())
