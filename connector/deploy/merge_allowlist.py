#!/usr/bin/env python3
"""Merge a host into the JS-runtime outbound allowlist settings object without dropping existing hosts.

stdin:  output of `dtctl get settings --schema builtin:dt-javascript-runtime.allowed-outbound-connections -o json --plain`
        (a list of settings objects, possibly empty, or an agent envelope {ok, result})
argv:   host to add (default api.anthropic.com); --out <file> for the merged object to `dtctl apply`
exit:   0 and prints "unchanged" when the host is already present (nothing written),
        0 and prints "merged <file>" when an existing object was updated,
        3 and prints "create" when no object exists yet (caller must `dtctl create settings`).
"""
import argparse
import json
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host", nargs="?", default="api.anthropic.com")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    raw = sys.stdin.read().strip()
    data = json.loads(raw) if raw else []
    if isinstance(data, dict) and "result" in data:
        data = data["result"]
    if isinstance(data, dict):
        data = [data]
    objs = [o for o in data if isinstance(o, dict) and "value" in o]
    if not objs:
        print("create")
        sys.exit(3)

    obj = objs[0]
    value = obj["value"]
    block = value.get("allowedOutboundConnections", value)
    hosts = list(block.get("hostList", []))
    if a.host in hosts:
        print("unchanged")
        return
    hosts.append(a.host)
    block["hostList"] = hosts
    block.setdefault("enforced", True)
    if "allowedOutboundConnections" in value:
        value["allowedOutboundConnections"] = block
    out = {k: obj[k] for k in ("objectId", "schemaId", "scope", "value") if k in obj}
    with open(a.out, "w") as fh:
        json.dump(out, fh, indent=2)
    print(f"merged {a.out}")


if __name__ == "__main__":
    main()
