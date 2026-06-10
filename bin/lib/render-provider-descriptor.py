#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml", "jinja2"]
# ///
"""
render-provider-descriptor.py — PoC renderer for Provider Descriptors
(ADR-0026, schema: docs/architecture/DMF Provider Descriptor Model.md).

Reads a single descriptor YAML and an env-inventory directory, validates
the descriptor against the §3.1 MUST rules, then renders
descriptor.group_vars_file.template into

    <env-inventory-dir>/<descriptor.group_vars_file.path>

using Jinja2 in strict-undefined mode with exactly two namespaces in
scope (§3.3):

    1. Every inputs[].name as a top-level variable. Operator-supplied
       value comes from stdin JSON; falls back to the input's `default`
       when absent. Missing required inputs error out.
    2. A `secrets` dict where `secrets.<name>.indirection` evaluates to
       the literal indirection string declared on that secret. The
       renderer emits the indirection verbatim — Ansible re-evaluates
       it at playbook time.

Any other variable referenced in the template (e.g. a stray
`{{ vault_foo }}`) raises a render error.

CLI:
    render-provider-descriptor.py <descriptor.yaml> <env-inventory-dir>

stdin: JSON object of operator-supplied input values, keyed by input
       name. Omit a key to fall back to the input's `default`.

Exit codes:
    0 — rendered successfully
    1 — validation, render, or I/O error (message on stderr)
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import yaml
from jinja2 import Environment, StrictUndefined
from jinja2 import exceptions as jinja2_exceptions


VALID_PROFILES = {"cloud", "flypack-offline", "flypack-online"}
REQUIRED_SECRET_FIELDS = (
    "name",
    "prompt",
    "bundle_path",
    "vault_path",
    "vault_field",
    "export_var",
    "inventory_var",
    "indirection",
)


def die(msg: str) -> "None":
    print(f"render-provider-descriptor: {msg}", file=sys.stderr)
    sys.exit(1)


def validate_descriptor(desc: dict[str, Any], descriptor_path: Path) -> None:
    """Enforce the §3.1 MUST rules called out in the brief."""
    if not isinstance(desc, dict):
        die(f"{descriptor_path}: top-level must be a YAML mapping")

    # Rule 4: applies_to_profiles non-empty and subset of known profiles.
    profiles = desc.get("applies_to_profiles")
    if not isinstance(profiles, list) or not profiles:
        die(f"{descriptor_path}: applies_to_profiles must be a non-empty list")
    bad = [p for p in profiles if p not in VALID_PROFILES]
    if bad:
        die(
            f"{descriptor_path}: applies_to_profiles contains unknown profile(s): "
            f"{bad!r} (allowed: {sorted(VALID_PROFILES)})"
        )

    # Rule 5: group_vars_file.path starts with group_vars/all/.
    gvf = desc.get("group_vars_file")
    if not isinstance(gvf, dict):
        die(f"{descriptor_path}: group_vars_file must be a mapping")
    path = gvf.get("path", "")
    template = gvf.get("template")
    if not isinstance(path, str) or not path.startswith("group_vars/all/"):
        die(
            f"{descriptor_path}: group_vars_file.path must start with "
            f"'group_vars/all/' (got {path!r})"
        )
    if not isinstance(template, str) or not template.strip():
        die(f"{descriptor_path}: group_vars_file.template must be a non-empty string")

    # Rule 2 + PoC §3.1.1 pragmatism: every secret carries all required
    # fields (no literal secret-value detection; we just enforce that
    # the *declared* indirection structure is present and non-empty).
    secrets = desc.get("secrets", [])
    if not isinstance(secrets, list):
        die(f"{descriptor_path}: secrets must be a list (may be empty)")
    for i, sec in enumerate(secrets):
        if not isinstance(sec, dict):
            die(f"{descriptor_path}: secrets[{i}] must be a mapping")
        for field in REQUIRED_SECRET_FIELDS:
            val = sec.get(field)
            if not isinstance(val, str) or not val.strip():
                die(
                    f"{descriptor_path}: secrets[{i}].{field} must be a "
                    f"non-empty string (got {val!r})"
                )

    # inputs[] must be a list (may be empty); each entry needs name.
    inputs = desc.get("inputs", [])
    if not isinstance(inputs, list):
        die(f"{descriptor_path}: inputs must be a list (may be empty)")
    for i, inp in enumerate(inputs):
        if not isinstance(inp, dict):
            die(f"{descriptor_path}: inputs[{i}] must be a mapping")
        name = inp.get("name")
        if not isinstance(name, str) or not name.strip():
            die(f"{descriptor_path}: inputs[{i}].name must be a non-empty string")


def build_context(
    desc: dict[str, Any],
    supplied: dict[str, Any],
    descriptor_path: Path,
) -> dict[str, Any]:
    """Build the Jinja render context per §3.3.

    Returns a dict containing:
      - every inputs[].name → operator-supplied value (or descriptor default)
      - secrets → {name: {'indirection': <literal string>}}

    Missing required inputs (no stdin value, no default) raise.
    """
    ctx: dict[str, Any] = {}

    for inp in desc.get("inputs", []):
        name = inp["name"]
        required = bool(inp.get("required", False))
        if name in supplied:
            ctx[name] = supplied[name]
        elif "default" in inp:
            ctx[name] = inp["default"]
        elif required:
            die(
                f"{descriptor_path}: required input {name!r} not supplied "
                f"and no default declared"
            )
        # else: unset → strict-undefined will raise if the template
        # references it. That's the intended behavior.

    secrets_ns: dict[str, dict[str, str]] = {}
    for sec in desc.get("secrets", []):
        secrets_ns[sec["name"]] = {"indirection": sec["indirection"]}
    ctx["secrets"] = secrets_ns

    return ctx


def _yaml_finalize(value: Any) -> Any:
    """Coerce Python booleans to YAML lowercase form at template emit time.

    Jinja's default {{ }} stringification of `True` / `False` yields
    Python repr (capitalized), which is not valid YAML 1.2. Descriptor
    templates expect to drop boolean inputs directly into a YAML scalar
    position (`accept_routes: {{ accept_routes }}`), so we normalize
    here. Non-bool values pass through unchanged so strings still
    render verbatim and `secrets.<name>.indirection` (a plain string)
    is unaffected.
    """
    if isinstance(value, bool):
        return "true" if value else "false"
    return value


def render(desc: dict[str, Any], ctx: dict[str, Any], descriptor_path: Path) -> str:
    env = Environment(
        undefined=StrictUndefined,
        keep_trailing_newline=True,
        autoescape=False,
        finalize=_yaml_finalize,
    )
    template_src = desc["group_vars_file"]["template"]
    try:
        template = env.from_string(template_src)
        return template.render(**ctx)
    except jinja2_exceptions.UndefinedError as exc:
        die(
            f"{descriptor_path}: template references an undefined variable: "
            f"{exc.message}. Use an entry in inputs[] or secrets.<name>.indirection."
        )
    except jinja2_exceptions.TemplateSyntaxError as exc:
        die(
            f"{descriptor_path}: template syntax error at line {exc.lineno}: "
            f"{exc.message}"
        )
    # Unreachable — die() exits. Satisfies static analyzers.
    return ""


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: render-provider-descriptor.py <descriptor.yaml> <env-inventory-dir>",
            file=sys.stderr,
        )
        return 1

    descriptor_path = Path(argv[1])
    inventory_dir = Path(argv[2])

    if not descriptor_path.is_file():
        die(f"descriptor not found: {descriptor_path}")

    # stdin JSON. Empty stdin → no operator-supplied values, fall back
    # to descriptor defaults for everything.
    raw = sys.stdin.read().strip()
    if raw:
        try:
            supplied = json.loads(raw)
        except json.JSONDecodeError as exc:
            die(f"stdin is not valid JSON: {exc}")
        if not isinstance(supplied, dict):
            die("stdin JSON must be an object (mapping input names to values)")
    else:
        supplied = {}

    try:
        with descriptor_path.open("r", encoding="utf-8") as fh:
            desc = yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        die(f"{descriptor_path}: YAML parse error: {exc}")

    validate_descriptor(desc, descriptor_path)

    ctx = build_context(desc, supplied, descriptor_path)
    rendered = render(desc, ctx, descriptor_path)

    rel_path = desc["group_vars_file"]["path"]
    out_path = inventory_dir / rel_path
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(rendered, encoding="utf-8")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
