#!/usr/bin/env python3
"""Build the importable workflow JSON from the task sources.

- Inlines workflow/lib/common.js into every task that carries the marker `// @include common.js`
  (a workflow task is a single self-contained script; it cannot import sibling files).
- Writes the built scripts to workflow/build/<task>.js (these are exactly what the tests run under Node).
- Writes workflow/claude-usage-connector.json (schedule 15:00 UTC daily, 4 Run-JavaScript tasks).

Usage: python3 workflow/build.py [--out workflow/claude-usage-connector.json]
"""
import argparse
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
LIB = HERE / "lib" / "common.js"
TASKS = HERE / "tasks"
BUILD = HERE / "build"
MARKER = "// @include common.js"

TASK_ORDER = ["resolve_config", "enterprise_analytics", "console_claude_code", "team_reminder"]

DESCRIPTIONS = {
    "resolve_config": "Build the config from the workflow input (org_type, credential, base URL are input-only); run params may override lookback/dry_run/debug only.",
    "enterprise_analytics": "Claude Enterprise Analytics API: per-user cost + usage for the last 10 days -> claude.usage.daily bizevents.",
    "console_claude_code": "Claude Console Admin API: usage_report/claude_code (per user) + usage_report/messages (org-level api) -> bizevents.",
    "team_reminder": "Team plan: no API. Logs the reminder to run csv-import/import_team_spend.py.",
}

GATES = {
    "enterprise_analytics": "enterprise",
    "console_claude_code": "console",
    "team_reminder": "team",
}


def build_script(name: str) -> str:
    src = (TASKS / f"{name}.js").read_text()
    if MARKER in src:
        src = src.replace(MARKER, LIB.read_text())
    return src


def build_workflow(scripts: dict) -> dict:
    tasks = {}
    tasks["resolve_config"] = {
        "name": "resolve_config",
        "action": "dynatrace.automations:run-javascript",
        "description": DESCRIPTIONS["resolve_config"],
        "input": {"script": scripts["resolve_config"]},
        "position": {"x": 0, "y": 1},
        "predecessors": [],
        "active": True,
    }
    x = -1
    for name in ["enterprise_analytics", "console_claude_code", "team_reminder"]:
        tasks[name] = {
            "name": name,
            "action": "dynatrace.automations:run-javascript",
            "description": DESCRIPTIONS[name],
            "input": {"script": scripts[name]},
            "position": {"x": x, "y": 2},
            "predecessors": ["resolve_config"],
            "active": True,
            "conditions": {
                "states": {"resolve_config": "OK"},
                "custom": '{{ result("resolve_config").org_type == "%s" }}' % GATES[name],
                "else": "SKIP",
            },
            "timeout": 110,
        }
        x += 1

    return {
        "title": "Claude usage connector (dt-ai-observability-claude, layer 3)",
        "description": (
            "Daily import of official Claude usage/cost per developer into bizevents event.type=claude.usage.daily. "
            "Set the workflow input org_type (enterprise|console|team) and credential_id (vault entry with the Anthropic key). "
            "Enterprise: Analytics API key. Console: Admin API key. Team: CSV importer (this workflow only logs a reminder)."
        ),
        "type": "STANDARD",
        "isPrivate": True,  # only the owner edits/runs it: inputs carry credential_name/base URL (deploy/render_workflow.py --public opts out)
        "schemaVersion": 3,
        "hourlyExecutionLimit": 10,
        "input": {
            "org_type": "enterprise",
            "credential_id": "",
            "credential_name": "",
            "anthropic_base_url": "https://api.anthropic.com",
            "allow_custom_base_url": False,
            "org_id": "",
            "enterprise_lookback_days": 10,
            "console_lookback_days": 3,
            "console_include_api_usage": True,
            "dry_run": False,
            "console_debug": False,
        },
        "trigger": {
            "schedule": {
                "isActive": True,
                "isFaulty": False,
                "trigger": {"type": "time", "time": "15:00"},
                "rule": None,
                "filterParameters": {},
                "timezone": "UTC",
                "inputs": {},
            }
        },
        "tasks": tasks,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(HERE / "claude-usage-connector.json"))
    args = ap.parse_args()

    BUILD.mkdir(exist_ok=True)
    scripts = {}
    for name in TASK_ORDER:
        scripts[name] = build_script(name)
        (BUILD / f"{name}.js").write_text(scripts[name])
        print(f"built {name}: {len(scripts[name]):,} chars")

    wf = build_workflow(scripts)
    pathlib.Path(args.out).write_text(json.dumps(wf, indent=2) + "\n")
    print(f"wrote {args.out} ({pathlib.Path(args.out).stat().st_size:,} bytes, {len(wf['tasks'])} tasks)")


if __name__ == "__main__":
    main()
