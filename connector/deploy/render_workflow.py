#!/usr/bin/env python3
"""Render the built workflow JSON with deployment-specific inputs filled in.

python3 deploy/render_workflow.py --org-type console --credential-id CREDENTIALS_VAULT-ABC --org-id acme \
        --out deploy/.out/claude-usage-connector.console.json [--id <existing workflow id>] [--title ...] [--public]

The rendered workflow is private by default (isPrivate: true); --public opts out.
"""
import argparse
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parent / "workflow" / "claude-usage-connector.json"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--org-type", required=True, choices=["enterprise", "console", "team"])
    ap.add_argument("--credential-id", default="")
    ap.add_argument("--credential-name", default="")
    ap.add_argument("--org-id", default="")
    ap.add_argument("--title", default=None)
    ap.add_argument("--id", default=None, help="existing workflow id (update in place)")
    ap.add_argument("--public", action="store_true", help="isPrivate=false (default: private — the inputs name the credential and base URL)")
    ap.add_argument("--private", action="store_true", help="kept for compatibility; private is the default")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    wf = json.loads(SRC.read_text())
    wf["input"]["org_type"] = a.org_type
    wf["input"]["credential_id"] = a.credential_id
    wf["input"]["credential_name"] = a.credential_name
    wf["input"]["org_id"] = a.org_id
    wf["trigger"]["schedule"]["inputs"] = {}  # API requires ScheduleInput objects here; workflow-level input is the source of truth
    if a.title:
        wf["title"] = a.title
    if a.id:
        wf["id"] = a.id
    wf["isPrivate"] = not a.public
    if a.org_type != "team" and not (a.credential_id or a.credential_name):
        raise SystemExit("--credential-id or --credential-name is required for enterprise/console")
    out = pathlib.Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(wf, indent=2) + "\n")
    print(out)


if __name__ == "__main__":
    main()
