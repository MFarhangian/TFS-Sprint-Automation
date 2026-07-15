#!/usr/bin/env python3
"""
Create sprint Tasks under recurring Product Backlog Items in Azure DevOps Server (TFS).

Usage:
  export AZURE_DEVOPS_PAT='your-personal-access-token'
  python3 scripts/create-sprint-tasks.py
  python3 scripts/create-sprint-tasks.py --parent-id 58200
  python3 scripts/create-sprint-tasks.py --dry-run
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def load_config(config_path: Path) -> dict:
    with config_path.open(encoding="utf-8") as handle:
        return json.load(handle)


def build_base_url(config: dict) -> str:
    collection = urllib.parse.quote(config["collection"])
    project = urllib.parse.quote(config["project"])
    return f"{config['serverUrl'].rstrip('/')}/{collection}/{project}"


def request_json(
    method: str,
    url: str,
    pat: str,
    payload: dict | list | None = None,
    content_type: str = "application/json",
) -> dict | list:
    headers = {
        "Authorization": f"Basic {base64.b64encode(f':{pat}'.encode()).decode()}",
        "Accept": "application/json",
    }
    data = None
    if payload is not None:
        headers["Content-Type"] = content_type
        data = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read().decode("utf-8")
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {url} failed ({exc.code}): {error_body}") from exc


def get_work_item(base_url: str, pat: str, work_item_id: int) -> dict:
    url = f"{base_url}/_apis/wit/workitems/{work_item_id}?api-version=7.0"
    return request_json("GET", url, pat)


def find_existing_child_task(
    base_url: str,
    pat: str,
    parent_id: int,
    iteration_path: str,
    child_type: str,
) -> dict | None:
    wiql = {
        "query": (
            "SELECT [System.Id], [System.Title], [System.State] "
            "FROM WorkItemLinks "
            "WHERE "
            "[Source].[System.Id] = {parent_id} "
            "AND [System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward' "
            "AND [Target].[System.WorkItemType] = '{child_type}' "
            "AND [Target].[System.IterationPath] UNDER '{iteration_path}' "
            "MODE (MustContain)"
        ).format(
            parent_id=parent_id,
            child_type=child_type.replace("'", "''"),
            iteration_path=iteration_path.replace("'", "''"),
        )
    }
    result = request_json("POST", f"{base_url}/_apis/wit/wiql?api-version=7.0", pat, wiql)
    relations = result.get("workItemRelations") or []
    child_ids = [
        relation["target"]["id"]
        for relation in relations
        if relation.get("target") and relation["target"].get("id")
    ]
    if not child_ids:
        return None
    return {"id": child_ids[0], "alreadyExists": True}


def create_child_task(
    base_url: str,
    pat: str,
    config: dict,
    parent: dict,
) -> dict:
    parent_id = parent["id"]
    parent_url = parent["url"]
    title = parent["fields"]["System.Title"]
    child_type = config["childWorkItemType"]
    create_url = (
        f"{base_url}/_apis/wit/workitems/${urllib.parse.quote(child_type)}"
        "?api-version=7.0"
    )

    patch_document = [
        {"op": "add", "path": "/fields/System.Title", "value": title},
        {
            "op": "add",
            "path": "/fields/System.AssignedTo",
            "value": config["assignedTo"],
        },
        {
            "op": "add",
            "path": "/fields/System.IterationPath",
            "value": config["iterationPath"],
        },
        {
            "op": "add",
            "path": "/relations/-",
            "value": {
                "rel": "System.LinkTypes.Hierarchy-Reverse",
                "url": parent_url,
            },
        },
    ]

    if parent.get("fields", {}).get("System.AreaPath"):
        patch_document.append(
            {
                "op": "add",
                "path": "/fields/System.AreaPath",
                "value": parent["fields"]["System.AreaPath"],
            }
        )

    created = request_json(
        "POST",
        create_url,
        pat,
        patch_document,
        content_type="application/json-patch+json",
    )
    return {
        "id": created["id"],
        "title": title,
        "parentId": parent_id,
        "url": created.get("url"),
        "created": True,
    }


def resolve_parent_ids(base_url: str, pat: str, config: dict, explicit_ids: list[int]) -> list[int]:
    if explicit_ids:
        return explicit_ids

    wiql = {
        "query": (
            "SELECT [System.Id] FROM WorkItems "
            "WHERE [System.TeamProject] = @project "
            "AND [System.WorkItemType] = '{work_item_type}' "
            "AND [System.AssignedTo] = '{assigned_to}' "
            "AND [System.State] = '{state}' "
            "ORDER BY [System.Id]"
        ).format(
            work_item_type=config["parentWorkItemType"].replace("'", "''"),
            assigned_to=config["assignedTo"].replace("'", "''"),
            state=config["parentStateFilter"].replace("'", "''"),
        )
    }
    result = request_json("POST", f"{base_url}/_apis/wit/wiql?api-version=7.0", pat, wiql)
    return [item["id"] for item in result.get("workItems", [])]


def main() -> int:
    parser = argparse.ArgumentParser(description="Create sprint tasks for recurring PBIs.")
    parser.add_argument(
        "--config",
        default=Path(__file__).with_name("config.json"),
        type=Path,
        help="Path to config.json",
    )
    parser.add_argument(
        "--parent-id",
        action="append",
        type=int,
        dest="parent_ids",
        help="Parent PBI id. Can be passed multiple times.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Only show what would be created.",
    )
    args = parser.parse_args()

    pat = os.environ.get("AZURE_DEVOPS_PAT") or os.environ.get("TFS_PAT")
    if not pat and not args.dry_run:
        print("Set AZURE_DEVOPS_PAT (or TFS_PAT) before running.", file=sys.stderr)
        return 1

    config = load_config(args.config)
    base_url = build_base_url(config)
    parent_ids = resolve_parent_ids(
        base_url,
        pat or "",
        config,
        args.parent_ids or config.get("parentIds", []),
    )

    if not parent_ids:
        print("No parent backlog items found.")
        return 0

    print(f"Sprint: {config['iterationPath']}")
    print(f"Parents: {parent_ids}")

    results: list[dict] = []
    for parent_id in parent_ids:
        parent = get_work_item(base_url, pat or "", parent_id)
        title = parent["fields"]["System.Title"]
        print(f"\nPBI {parent_id}: {title}")

        existing = find_existing_child_task(
            base_url,
            pat or "",
            parent_id,
            config["iterationPath"],
            config["childWorkItemType"],
        )
        if existing:
            print(f"  -> already has task {existing['id']} in this sprint")
            results.append(existing)
            continue

        if args.dry_run:
            print("  -> would create child task")
            results.append({"parentId": parent_id, "title": title, "dryRun": True})
            continue

        created = create_child_task(base_url, pat or "", config, parent)
        print(f"  -> created task {created['id']}")
        results.append(created)

    print("\nSummary:")
    for item in results:
        if item.get("created"):
            print(f"  CREATED Task {item['id']} under PBI {item['parentId']}")
        elif item.get("alreadyExists"):
            print(f"  SKIPPED existing Task {item['id']}")
        elif item.get("dryRun"):
            print(f"  DRY-RUN would create task under PBI {item['parentId']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
