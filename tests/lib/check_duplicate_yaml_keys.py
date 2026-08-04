#!/usr/bin/env python3
"""Fail on duplicate mapping keys in the given YAML files.

T-489 (2026-08-04): charts/lucairn/values.yaml declared a top-level
`observability:` block TWICE (once at line 353 with just `enabled: true`,
again at line 548 with the real grafana.auth.jwt config). PyYAML's default
loader — like every stock YAML loader — silently keeps the LAST occurrence
and discards the first with no warning, so the first block's intent (in this
case harmless, since both agreed on `enabled: true`) went silently dead. A
future edit to the FIRST occurrence of a duplicated key would silently do
nothing, and nobody would notice until the deployed behavior didn't match
the values file an operator was reading.

This check parses each file with `yaml.compose()` (which returns the raw
Node tree, not constructed Python objects) and walks every mapping at every
nesting depth — not just the top level — looking for a scalar key that
appears twice as a direct child of the same mapping. This is the same shape
of check as yamllint's `key-duplicates` rule; it is implemented directly
here (rather than adding a yamllint dependency) because the kit test harness
already vendors its YAML tooling as small stdlib+PyYAML scripts (see
tests/lib/netpol_assert.py) and CI already provisions PyYAML for
tests/test_netpol_hardening.sh.

Usage:
  python3 tests/lib/check_duplicate_yaml_keys.py <file.yaml> [<file.yaml> ...]

Exit 0 = no duplicate keys in any file. Exit 1 = at least one duplicate,
each printed as "<file>: duplicate key '<key>' at <path> (line N, first
seen at line M)" on stderr.
"""
import sys

import yaml


def _key_text(key_node):
    if isinstance(key_node, yaml.ScalarNode):
        return key_node.value
    # Non-scalar keys (rare in Helm values files) — fall back to a stable
    # repr so a duplicate complex key is still reported rather than crashing.
    return repr(key_node.value)


def find_duplicates(node, path, errors):
    """Recursively walk a composed YAML Node tree collecting duplicate-key
    errors into `errors` (a list of strings). `path` is a dotted breadcrumb
    for the error message only."""
    if isinstance(node, yaml.MappingNode):
        seen = {}
        for key_node, value_node in node.value:
            key = _key_text(key_node)
            key_path = f"{path}.{key}" if path else key
            line = key_node.start_mark.line + 1
            if key in seen:
                errors.append(
                    f"duplicate key '{key}' at {key_path} "
                    f"(line {line}, first seen at line {seen[key]})"
                )
            else:
                seen[key] = line
            find_duplicates(value_node, key_path, errors)
    elif isinstance(node, yaml.SequenceNode):
        for index, item in enumerate(node.value):
            find_duplicates(item, f"{path}[{index}]", errors)
    # ScalarNode: nothing to recurse into.


def check_file(filename):
    file_errors = []
    with open(filename, "r", encoding="utf-8") as handle:
        try:
            for document in yaml.compose_all(handle):
                if document is None:
                    continue
                find_duplicates(document, "", file_errors)
        except yaml.YAMLError as exc:
            file_errors.append(f"could not parse as YAML: {exc}")
    return file_errors


def main(argv):
    if not argv:
        print("usage: check_duplicate_yaml_keys.py <file.yaml> [...]", file=sys.stderr)
        return 2

    any_errors = False
    for filename in argv:
        for message in check_file(filename):
            any_errors = True
            print(f"{filename}: {message}", file=sys.stderr)

    if any_errors:
        return 1

    print(f"ok: no duplicate keys in {len(argv)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
