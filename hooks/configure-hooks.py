#!/usr/bin/env python3
"""Manage the Claude Code side of the integration (shared by install.sh / install.ps1).

Sub-commands
  install-hooks   --hook-path P [--windows]      merge the 4 hook entries into ~/.claude/settings.json
  remove-hooks                                   remove only the entries that reference otel-hook.py
  write-attrs     --port N [--capture-prompts] [--os-type T] [--attr K=V ...]
                                                 write ~/.claude/otel-attrs.json (read by the hook)
  native-otel     --port N [--remove]            add/remove the Claude Code native OTel env block
  status                                         print what is configured

Mirrors the behaviour of src/claudeHooks.ts in the dt-ai-observability-vscode
asset: same hook command (`python3 "<path>" || true`, `python "<path>" || exit 0`
on Windows), same reserved `_` keys in otel-attrs.json. Unlike the extension it
never replaces hook entries it did not create. Python 3.6+, stdlib only.
"""
import argparse
import json
import os
import re
import sys
import time

CLAUDE_DIR = os.path.join(os.path.expanduser("~"), ".claude")
SETTINGS = os.path.join(CLAUDE_DIR, "settings.json")
ATTRS = os.path.join(CLAUDE_DIR, "otel-attrs.json")
EVENTS = ["PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop"]
MARK = "otel-hook.py"

# Claude Code native telemetry -> local collector (see managed-settings.example.json)
NATIVE_ENV = {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:{port}",
    "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "delta",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
}


def read_json(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except ValueError as e:
        sys.exit("%s is not valid JSON (%s); fix it or move it away first" % (path, e))


def write_json(path, data, backup=True):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if backup and os.path.exists(path):
        bak = "%s.bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
        with open(path, encoding="utf-8") as src, open(bak, "w", encoding="utf-8") as dst:
            dst.write(src.read())
        print("backup: %s" % bak)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
    print("written: %s" % path)


def hook_command(hook_path, windows):
    hook_path = hook_path.replace("\\", "/")
    if windows:
        return 'python "%s" || exit 0' % hook_path
    return 'python3 "%s" || true' % hook_path


def group_is_ours(group):
    hooks = group.get("hooks") if isinstance(group, dict) else None
    if not isinstance(hooks, list) or not hooks:
        return False
    return all(isinstance(h, dict) and MARK in str(h.get("command", "")) for h in hooks)


def cmd_install_hooks(a):
    settings = read_json(SETTINGS)
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    entry = {"hooks": [{"type": "command", "command": hook_command(a.hook_path, a.windows)}]}
    changed = False
    for ev in EVENTS:
        groups = hooks.get(ev)
        if not isinstance(groups, list):
            groups = []
        if any(group_is_ours(g) for g in groups):
            print("%s: hook already present, left untouched" % ev)
            continue
        groups.append(entry)
        hooks[ev] = groups
        changed = True
        print("%s: hook added" % ev)
    settings["hooks"] = hooks
    if changed:
        write_json(SETTINGS, settings)
    else:
        print("settings.json unchanged")


def cmd_remove_hooks(a):
    settings = read_json(SETTINGS)
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        print("no hooks configured")
        return
    changed = False
    for ev in list(hooks.keys()):
        groups = hooks.get(ev)
        if not isinstance(groups, list):
            continue
        kept = [g for g in groups if not group_is_ours(g)]
        if len(kept) != len(groups):
            changed = True
            print("%s: removed %d hook entr%s" % (ev, len(groups) - len(kept), "y" if len(groups) - len(kept) == 1 else "ies"))
        if kept:
            hooks[ev] = kept
        else:
            hooks.pop(ev, None)
    if hooks:
        settings["hooks"] = hooks
    else:
        settings.pop("hooks", None)
    if changed:
        write_json(SETTINGS, settings)
    else:
        print("no otel-hook.py entries found")


def cmd_write_attrs(a):
    attrs = {}
    if a.os_type:
        attrs["os.type"] = a.os_type
    for item in a.attr or []:
        if "=" not in item:
            sys.exit("--attr expects KEY=VALUE, got %r" % item)
        k, v = item.split("=", 1)
        k = k.strip()
        if not k or k.startswith("_") or any(c.isspace() for c in k):
            sys.exit("invalid attribute key %r (no spaces, must not start with '_')" % k)
        attrs[k] = v
    # Reserved keys written LAST so a custom attribute can never override them.
    attrs["_capture_prompts"] = "true" if a.capture_prompts else "false"
    attrs["_collector_port"] = str(a.port)
    write_json(ATTRS, attrs, backup=False)


def cmd_native_otel(a):
    settings = read_json(SETTINGS)
    env = settings.get("env")
    if not isinstance(env, dict):
        env = {}
    wanted = {k: v.format(port=a.port) for k, v in NATIVE_ENV.items()}
    changed = False
    if a.remove:
        for k, v in wanted.items():
            if env.get(k) == v:
                env.pop(k)
                changed = True
                print("env.%s removed" % k)
    else:
        for k, v in wanted.items():
            ours = k == "OTEL_EXPORTER_OTLP_ENDPOINT" and re.match(r"^http://127\.0\.0\.1:\d+/?$", str(env.get(k, "")))
            if k in env and env[k] != v and not ours:
                print("env.%s already set to %r, left untouched (wanted %r)" % (k, env[k], v))
                continue
            if env.get(k) != v:
                env[k] = v
                changed = True
                print("env.%s = %s" % (k, v))
    if env:
        settings["env"] = env
    else:
        settings.pop("env", None)
    if changed:
        write_json(SETTINGS, settings)
    else:
        print("settings.json unchanged")


def cmd_status(a):
    settings = read_json(SETTINGS)
    hooks = settings.get("hooks") or {}
    for ev in EVENTS:
        groups = hooks.get(ev) if isinstance(hooks, dict) else None
        ours = any(group_is_ours(g) for g in (groups or []))
        print("%-17s %s" % (ev + ":", "otel-hook.py" if ours else "-"))
    env = settings.get("env") or {}
    print("native OTel env: %s" % ("on (%s)" % env.get("OTEL_EXPORTER_OTLP_ENDPOINT") if env.get("CLAUDE_CODE_ENABLE_TELEMETRY") == "1" else "off"))
    attrs = read_json(ATTRS)
    print("otel-attrs.json: %s" % (json.dumps(attrs) if attrs else "missing"))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd")
    sub.required = True
    s = sub.add_parser("install-hooks"); s.add_argument("--hook-path", required=True); s.add_argument("--windows", action="store_true"); s.set_defaults(fn=cmd_install_hooks)
    s = sub.add_parser("remove-hooks"); s.set_defaults(fn=cmd_remove_hooks)
    s = sub.add_parser("write-attrs"); s.add_argument("--port", type=int, required=True); s.add_argument("--capture-prompts", action="store_true"); s.add_argument("--os-type", default=""); s.add_argument("--attr", action="append"); s.set_defaults(fn=cmd_write_attrs)
    s = sub.add_parser("native-otel"); s.add_argument("--port", type=int, required=True); s.add_argument("--remove", action="store_true"); s.set_defaults(fn=cmd_native_otel)
    s = sub.add_parser("status"); s.set_defaults(fn=cmd_status)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
