#!/usr/bin/env python3
"""Refresh config-pack/docs-keys-snapshot.json from the vendor's published docs.

Maintainer tool (needs network). The offline check (check.py) compares every
key the config pack writes against the key lists this script records, so a
misspelled or invented key fails the kit tests instead of being shipped.

Each source is fetched as the raw Markdown the docs site serves (the `.md`
variant of the page), never through a summarizer, and the key names are
extracted with fixed patterns:

  * Claude Code settings reference: every `### `key`` heading.
  * Claude Code environment variables: every `| `NAME` |` table row.
  * Claude Code mods admin page: the built-in guard's plugin id and its
    `allowManagedModsOnly` option, recorded only if both appear verbatim.
  * Claude Desktop (third-party) configuration reference: every key in the
    reference tables (`<br />`key``).

Usage: python3 config-pack/snapshot_docs_keys.py [--output PATH]
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

SOURCES = {
    "claude_code_settings": {
        "url": "https://code.claude.com/docs/en/settings-reference.md",
        "pattern": r"^### `([A-Za-z0-9_.]+)`",
    },
    "claude_code_env_vars": {
        "url": "https://code.claude.com/docs/en/env-vars.md",
        "pattern": r"^\| `([A-Z][A-Z0-9_]+)` \|",
    },
    "claude_code_mods_guard": {
        "url": "https://code.claude.com/docs/en/plugins/mods/admin.md",
        "pattern": None,
    },
    "claude_desktop_config": {
        "url": "https://claude.com/docs/third-party/claude-desktop/configuration.md",
        "pattern": r"<br />`([A-Za-z0-9_.]+)`",
    },
}

# The guard tokens the pack uses under `pluginConfigs`. Recorded only when the
# page carries each one verbatim.
MODS_GUARD_TOKENS = ("cc-plugin-sec-default@builtin", "allowManagedModsOnly")


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "lucairn-config-pack-snapshot/1"})
    with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 - fixed https URLs
        return resp.read().decode("utf-8")


def extract(name: str, text: str) -> list[str]:
    spec = SOURCES[name]
    if spec["pattern"] is None:
        return [tok for tok in MODS_GUARD_TOKENS if tok in text]
    flags = re.MULTILINE
    return sorted(set(re.findall(spec["pattern"], text, flags)))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--output",
        default=str(Path(__file__).resolve().parent / "docs-keys-snapshot.json"),
    )
    args = parser.parse_args()

    today = _dt.date.today().isoformat()
    out = {
        "_comment": (
            "Key names extracted from the vendor's raw Markdown docs by "
            "config-pack/snapshot_docs_keys.py. check.py fails if the config "
            "pack writes a key that is not listed here."
        ),
        "fetched_on": today,
        "sources": {},
    }
    for name, spec in SOURCES.items():
        text = fetch(spec["url"])
        keys = extract(name, text)
        if not keys:
            print(f"error: no keys extracted from {spec['url']}", file=sys.stderr)
            return 1
        out["sources"][name] = {
            "url": spec["url"],
            "fetched_on": today,
            "page_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "keys": keys,
        }
        print(f"{name}: {len(keys)} keys from {spec['url']}")

    Path(args.output).write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
