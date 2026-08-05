#!/usr/bin/env python3
"""
Replicate all projects from the parent Workato workspace into a managed
customer (sub-tenant). Invoked by Terraform as a local-exec provisioner.

For each parent project (minus EXCLUDE_PROJECTS):
  1. Create an auto-generated export manifest at the project's root folder
  2. Export + download the package zip
  3. Create a same-named project folder in the target tenant
  4. Import the package into it

Environment variables:
  WORKATO_API_TOKEN   OEM API token
  TARGET_ENV_ID       managed_user_id of the target tenant
  EXCLUDE_PROJECTS    comma-separated project names to skip (default: Home)
  WORKATO_BASE_URL    default: https://www.workato.com
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("WORKATO_BASE_URL", "https://www.workato.com")
TOKEN = os.environ["WORKATO_API_TOKEN"]
ENV_ID = os.environ["TARGET_ENV_ID"]
EXCLUDE = {n.strip() for n in os.environ.get("EXCLUDE_PROJECTS", "Home").split(",") if n.strip()}


def api(path, body=None, raw=None, ct="application/json", method=None):
    req = urllib.request.Request(
        f"{BASE}{path}",
        data=raw if raw is not None else (json.dumps(body).encode() if body else None),
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": ct},
        method=method or ("POST" if (body or raw is not None) else "GET"),
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def unwrap(d):
    return d["result"] if isinstance(d, dict) and "result" in d else d


def poll(path, attempts=60, wait=3):
    for _ in range(attempts):
        st = unwrap(api(path))
        if st["status"] != "in_progress":
            return st
        time.sleep(wait)
    return st


def main():
    projects = [p for p in unwrap(api("/api/projects?per_page=100")) if p["name"] not in EXCLUDE]
    print(f"Replicating {len(projects)} project(s) into tenant {ENV_ID}: "
          + ", ".join(p["name"] for p in projects), flush=True)

    existing = {f["name"]: f["id"]
                for f in unwrap(api(f"/api/managed_users/{ENV_ID}/folders?per_page=100"))}
    failures = []

    for p in projects:
        print(f"\n== {p['name']} (project {p['id']})", flush=True)

        # 1-2. Export the whole project from the parent workspace
        try:
            manifest = unwrap(api("/api/export_manifests", {"export_manifest": {
                "name": f"tenant-replication {p['name']}",
                "folder_id": p["folder_id"],
                "auto_generate_assets": True,
                "auto_run": True,
            }}))
        except urllib.error.HTTPError as e:
            print(f"   SKIP: manifest failed ({e.code}: {e.read().decode()[:200]})", flush=True)
            failures.append(p["name"])
            continue

        st = poll(f"/api/packages/{manifest['package']['id']}")
        if st["status"] != "completed":
            print(f"   SKIP: export {st['status']}: {st.get('error')}", flush=True)
            failures.append(p["name"])
            api(f"/api/export_manifests/{manifest['id']}", method="DELETE")
            continue
        zip_bytes = urllib.request.urlopen(st["download_url"]).read()
        api(f"/api/export_manifests/{manifest['id']}", method="DELETE")
        print(f"   exported package ({len(zip_bytes) // 1024} KB)", flush=True)

        # 3. Same-named project folder in the target tenant
        if p["name"] in existing:
            folder_id = existing[p["name"]]
        else:
            folder = unwrap(api(f"/api/managed_users/{ENV_ID}/folders", {"name": p["name"]}))
            folder_id = folder["id"]
            existing[p["name"]] = folder_id
        print(f"   target folder {folder_id}", flush=True)

        # 4. Import
        imp = unwrap(api(
            f"/api/managed_users/{ENV_ID}/imports?folder_id={folder_id}&restart_recipes=true",
            raw=zip_bytes, ct="application/octet-stream"))
        st = poll(f"/api/managed_users/{ENV_ID}/imports/{imp['id']}")
        if st["status"] != "completed":
            print(f"   FAILED: import {st['status']}: {st.get('error')}", flush=True)
            failures.append(p["name"])
            continue
        print(f"   imported OK ({len(st.get('recipe_status', []))} recipe(s))", flush=True)

    if failures:
        sys.exit(f"\nReplication finished with failures: {', '.join(failures)}")
    print(f"\nAll projects replicated into tenant {ENV_ID}.", flush=True)


if __name__ == "__main__":
    main()
