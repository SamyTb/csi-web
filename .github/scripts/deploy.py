#!/usr/bin/env python3
"""
Deploy the recipes tracked in this repo to a Workato managed-customer environment.

Flow (Workato OEM Recipe Lifecycle Management):
  1. Collect recipe IDs from recipes/*.recipe.json
  2. Build an export manifest at the source project's root folder, selecting the
     repo's recipes plus their reachable dependencies (connections, custom
     adapters, project properties)
  3. Export the package zip and download it
  4. Import the zip into the target managed user's "CSI Web" folder (created if
     missing)

Environment variables:
  WORKATO_API_TOKEN    OEM API token (required)
  TARGET_ENV_ID        managed_user_id of the target environment (required)
  TARGET_FOLDER_NAME   destination folder in the target env (default: CSI Web)
  WORKATO_BASE_URL     default: https://www.workato.com
"""

import glob
import json
import os
import sys
import time
import urllib.request

BASE = os.environ.get("WORKATO_BASE_URL", "https://www.workato.com")
TOKEN = os.environ["WORKATO_API_TOKEN"]
ENV_ID = os.environ["TARGET_ENV_ID"]
FOLDER_NAME = os.environ.get("TARGET_FOLDER_NAME", "CSI Web")


def api(path, body=None, raw=None, ct="application/json", method=None):
    req = urllib.request.Request(
        f"{BASE}{path}",
        data=raw if raw is not None else (json.dumps(body).encode() if body else None),
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": ct},
        method=method or ("POST" if (body or raw is not None) else "GET"),
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        sys.exit(f"ERROR: {method or 'GET/POST'} {path} -> HTTP {e.code}: {e.read().decode()[:500]}")


def unwrap(d):
    return d["result"] if isinstance(d, dict) and "result" in d else d


def main():
    # 1. Recipes tracked in the repo
    files = sorted(glob.glob("recipes/*.recipe.json"))
    if not files:
        sys.exit("ERROR: no recipes/*.recipe.json files found")
    recipes = [json.load(open(f)) for f in files]
    recipe_ids = {r["id"] for r in recipes}
    project_ids = {r["project_id"] for r in recipes}
    if len(project_ids) > 1:
        sys.exit(f"ERROR: recipes span multiple projects: {project_ids}")
    project_id = project_ids.pop()
    print(f"Deploying {len(recipe_ids)} recipe(s) to env {ENV_ID}: "
          + ", ".join(r["name"] for r in recipes))

    # 2. Source project root folder
    projects = unwrap(api("/api/projects?per_page=100"))
    project = next((p for p in projects if p["id"] == project_id), None)
    if not project:
        sys.exit(f"ERROR: source project {project_id} not found")
    root_folder = project["folder_id"]

    # 3. Manifest: repo recipes + their reachable dependencies
    d = unwrap(api(f"/api/export_manifests/folder_assets?folder_id={root_folder}"))
    assets = d["assets"] if isinstance(d, dict) else d
    by_key = {(a["type"], a["id"]): a for a in assets}
    selected = {}
    for a in assets:
        if a["type"] == "recipe" and a["id"] in recipe_ids:
            selected[(a["type"], a["id"])] = a
            for dep in a.get("deps", []):
                k = (dep["type"], dep["id"])
                if k in by_key and not dep.get("unreachable"):
                    selected[k] = by_key[k]
    missing = recipe_ids - {a["id"] for a in selected.values() if a["type"] == "recipe"}
    if missing:
        sys.exit(f"ERROR: recipe ids not found in source workspace folder: {missing}")
    sel = [dict(a, checked=True) for a in selected.values()]
    print("Package contents: " + ", ".join(f"{a['type']}:{a['name']}" for a in sel))

    manifest = unwrap(api("/api/export_manifests", {"export_manifest": {
        "name": f"CI deploy {os.environ.get('GITHUB_REF_NAME', 'manual')} "
                f"{os.environ.get('GITHUB_SHA', '')[:7]}",
        "folder_id": root_folder,
        "assets": sel,
        "auto_run": True,
    }}))

    # 4. Export package
    pkg_id = manifest["package"]["id"]
    for _ in range(60):
        st = unwrap(api(f"/api/packages/{pkg_id}"))
        if st["status"] != "in_progress":
            break
        time.sleep(3)
    if st["status"] != "completed":
        sys.exit(f"ERROR: export {st['status']}: {st.get('error')}")
    zip_bytes = urllib.request.urlopen(st["download_url"]).read()
    print(f"Export completed ({len(zip_bytes) // 1024} KB)")

    # Manifest was only needed for this export; remove to avoid clutter
    api(f"/api/export_manifests/{manifest['id']}", method="DELETE")

    # 5. Destination folder in target env (create if missing)
    folders = unwrap(api(f"/api/managed_users/{ENV_ID}/folders?per_page=100"))
    folder = next((f for f in folders if f["name"] == FOLDER_NAME), None)
    if not folder:
        folder = unwrap(api(f"/api/managed_users/{ENV_ID}/folders", {"name": FOLDER_NAME}))
        print(f"Created folder '{FOLDER_NAME}' (id {folder['id']}) in env {ENV_ID}")
    folder_id = folder["id"]

    # 6. Import
    imp = unwrap(api(
        f"/api/managed_users/{ENV_ID}/imports?folder_id={folder_id}&restart_recipes=true",
        raw=zip_bytes, ct="application/octet-stream"))
    for _ in range(60):
        st = unwrap(api(f"/api/managed_users/{ENV_ID}/imports/{imp['id']}"))
        if st["status"] != "in_progress":
            break
        time.sleep(3)
    print("Import status:", json.dumps(st, indent=2))
    if st["status"] != "completed":
        sys.exit(f"ERROR: import {st['status']}: {st.get('error')}")
    print(f"Deploy to env {ENV_ID} completed.")


if __name__ == "__main__":
    main()
