#!/usr/bin/env python3
"""Render collector/otel-collector.yaml into ~/.dt-ai-obs/otel-collector.yaml.

Replaces the ${env:NAME} placeholders with literal values (except
DT_INGEST_TOKEN, which stays an environment reference resolved by the service
wrapper), appends custom resource attributes and, when --capture-prompts is
given, removes the transform/redact_content processor from the pipelines.

Only the Python standard library is used (Python 3.6+).
"""
import argparse
import json
import re
import sys


def yaml_string(value):
    # JSON string == valid YAML double-quoted scalar. '$' is doubled because the
    # collector expands ${env:...} inside config values ('$$' is a literal '$').
    return json.dumps(str(value).replace("$", "$$"))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--template", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--endpoint", required=True)
    p.add_argument("--email", default="")
    p.add_argument("--environment", default="demo")
    p.add_argument("--os-type", default="")
    p.add_argument("--collector-port", type=int, default=4318)
    p.add_argument("--grpc-port", type=int, default=4317)
    p.add_argument("--health-port", type=int, default=13133)
    p.add_argument("--capture-prompts", action="store_true")
    p.add_argument("--no-debug-exporter", action="store_true",
                   help="drop the debug exporter (quieter collector log)")
    p.add_argument("--attr", action="append", default=[], metavar="KEY=VALUE",
                   help="custom resource attribute (repeatable)")
    a = p.parse_args()

    with open(a.template, encoding="utf-8") as f:
        text = f.read()

    values = {
        "DT_OTLP_ENDPOINT": a.endpoint,
        "USER_EMAIL": a.email,
        "DT_ENVIRONMENT": a.environment,
        "OS_TYPE": a.os_type,
        "COLLECTOR_PORT": str(a.collector_port),
        "GRPC_PORT": str(a.grpc_port),
        "HEALTH_PORT": str(a.health_port),
    }

    def sub(m):
        name = m.group(1)
        if name == "DT_INGEST_TOKEN":
            return m.group(0)  # stays an env reference, injected by the wrapper
        if name not in values:
            sys.exit("render-config: unknown placeholder ${env:%s}" % name)
        raw = values[name]
        # Inside an already double-quoted scalar, insert the escaped body only.
        quoted = yaml_string(raw)
        return quoted[1:-1] if m.group(0).startswith("${") and _inside_quotes(text, m.start()) else raw

    def _inside_quotes(s, pos):
        line_start = s.rfind("\n", 0, pos) + 1
        return s[line_start:pos].count('"') % 2 == 1

    text = re.sub(r"\$\{env:([A-Z_]+)\}", sub, text)

    attrs = []
    for item in a.attr:
        if "=" not in item:
            sys.exit("render-config: --attr expects KEY=VALUE, got %r" % item)
        k, v = item.split("=", 1)
        k = k.strip()
        if not k or k.startswith("_") or re.search(r"\s", k):
            sys.exit("render-config: invalid attribute key %r" % k)
        attrs.append("      - { key: %s, value: %s, action: upsert }" % (yaml_string(k), yaml_string(v)))
    marker = "      # install.sh / install.ps1 append custom attributes (squad, cost_center, ...) here."
    if marker not in text:
        sys.exit("render-config: custom attribute marker not found in template")
    text = text.replace(marker, "\n".join(attrs) if attrs else marker.replace("append", "found no"))

    if not a.email:
        # No e-mail configured: keep Claude Code's own user.email on native
        # telemetry and do not stamp an empty one on the resource.
        text = text.replace("transform/native_email, ", "")
        text = re.sub(r"\n\s*- \{ key: user\.email,[^\n]*", "", text)

    if a.capture_prompts:
        if "transform/redact_content, " not in text:
            sys.exit("render-config: transform/redact_content not found in pipelines")
        text = text.replace("transform/redact_content, ", "")

    if a.no_debug_exporter:
        text = text.replace("exporters:  [debug, otlp_http/dynatrace]", "exporters:  [otlp_http/dynatrace]")

    with open(a.out, "w", encoding="utf-8") as f:
        f.write(text)
    print("rendered %s" % a.out)


if __name__ == "__main__":
    main()
