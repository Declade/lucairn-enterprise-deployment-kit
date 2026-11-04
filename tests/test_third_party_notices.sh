#!/usr/bin/env bash
# test_third_party_notices.sh — the kit ships the notices and licence texts of
# the third-party models and data its 2.0 images redistribute (kit 2.0 PRD row
# 8; owner's decision "Kit now, images in 2.0.1").
#
#   1. licenses/NOTICE is the recorded byte copy of the product repository's
#      NOTICE at the 2.0.0 image commit (sha256 in licenses/README.md).
#   2. Every file in licenses/ is listed exactly once in the licenses/README.md
#      table with its sha256, and every listed file exists with that sha256.
#   3. Every model the NOTICE names for the sidecar image, and every licence
#      family it cites, has its licence text here.
#   4. The release tarball (scripts/package-release.sh = `git archive HEAD`)
#      carries licenses/: every file is tracked and none is export-ignored.
#      (The customer bundle side is asserted in tests/test_lucairn_cli.sh.)
#   5. README.md and INSTALL.md point customers at licenses/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIC="$ROOT/licenses"
fail() { echo "third-party notices: FAIL: $*" >&2; exit 1; }

[ -d "$LIC" ] || fail "licenses/ is missing"
[ -f "$LIC/NOTICE" ] || fail "licenses/NOTICE is missing"
[ -f "$LIC/README.md" ] || fail "licenses/README.md is missing"

python3 - "$LIC" <<'PY'
import hashlib, os, re, sys

lic = sys.argv[1]
def fail(msg):
    print(f"third-party notices: FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

readme = open(os.path.join(lic, "README.md"), encoding="utf-8").read()
rows = re.findall(r"^\| `([^`]+)` \|.*\| `([0-9a-f]{64})` \|$", readme, re.M)
listed = {}
for name, digest in rows:
    if name in listed:
        fail(f"licenses/README.md lists {name} twice")
    listed[name] = digest
present = sorted(f for f in os.listdir(lic) if f != "README.md")
for name in present:
    if name not in listed:
        fail(f"licenses/{name} is not listed in licenses/README.md")
for name, digest in sorted(listed.items()):
    path = os.path.join(lic, name)
    if not os.path.isfile(path):
        fail(f"licenses/README.md lists {name}, which is missing")
    actual = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if actual != digest:
        fail(f"licenses/{name} has sha256 {actual}, licenses/README.md records {digest}")

# 1. NOTICE = the recorded copy of the product repository's NOTICE at 35dd235d.
NOTICE_SHA = "3b06c0920ffbd9e64b90290bfeec86c2d36a1ef0e5e3a6514abc6ef812434556"
if listed.get("NOTICE") != NOTICE_SHA:
    fail("licenses/NOTICE is not the recorded copy of the product NOTICE at 35dd235d")
if "35dd235d52d55ae597ee062c3e56ab9de5185c12" not in readme:
    fail("licenses/README.md does not name the product commit its NOTICE copy comes from")

# 3. Every sidecar model / licence family the NOTICE names has its text here.
notice = open(os.path.join(lic, "NOTICE"), encoding="utf-8").read()
needs = {
    "urchade/gliner_multi-v2.1": "Apache-2.0.txt",
    "microsoft/mdeberta-v3-base": "MIT-DeBERTa.txt",
    "en_core_web_md 3.8.0": "spaCy-model-sources-en_core_web_md-3.8.0.txt",
    "de_core_news_lg 3.8.0": "spaCy-model-sources-de_core_news_lg-3.8.0.txt",
    "torch 2.14.1+cpu": "PyTorch-2.14.1-LICENSE.txt",
    "langdetect 1.0.9": "langdetect-1.0.9-NOTICE.txt",
    "Faker 30.8.2": "MIT-Faker-30.8.2.txt",
    "smashew/NameDatabases": "Unlicense-NameDatabases.txt",
    "spaCy 3.8.13": "MIT-spaCy-3.8.13.txt",
    "Creative Commons Attribution 4.0": "CC-BY-4.0.txt",
    "CC0": "CC0-1.0.txt",
    "UNICODE LICENSE V3": "Unicode-License-V3.txt",
    "LLVM-exception": "SPDX-LLVM-exception.txt",
    "BSD-2-Clause": "SPDX-BSD-2-Clause.txt",
    "BSD-3-Clause": "SPDX-BSD-3-Clause.txt",
    "BSL-1.0": "SPDX-BSL-1.0.txt",
}
for phrase, text in needs.items():
    if phrase not in notice:
        fail(f"licenses/NOTICE no longer names '{phrase}'; review the licence set")
    if text not in listed:
        fail(f"licenses/NOTICE names '{phrase}' but licenses/{text} is missing")
both_models = ("en_core_web_md", "de_core_news_lg")
if "MIT-spaCy-models-3.8.0.txt" not in listed or not all(m in readme for m in both_models):
    fail("the spaCy models' MIT LICENSE is missing")
# The WordNet 3.0 notice must appear on all copies of en_core_web_md.
if "WordNet 3.0 Copyright 2006 by Princeton University" not in open(
        os.path.join(lic, "spaCy-model-sources-en_core_web_md-3.8.0.txt"), encoding="utf-8").read():
    fail("the WordNet 3.0 notice is missing from the en_core_web_md sources file")
print(f"third-party notices: {len(listed)} files listed with sha256; NOTICE = product 35dd235d copy; licence set complete")
PY

# 4. The release tarball is `git archive HEAD`: licenses/ must be tracked and
# not export-ignored.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  for f in "$LIC"/*; do
    rel="licenses/$(basename "$f")"
    git -C "$ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 \
      || fail "$rel is not tracked by git, so the release tarball (git archive HEAD) would not carry it"
    attr="$(git -C "$ROOT" check-attr export-ignore -- "$rel" | sed 's/.*: export-ignore: //')"
    [ "$attr" = "unspecified" ] || fail "$rel is export-ignored ($attr); the release tarball would drop it"
  done
  grep -q 'git -C "$ROOT" archive --format=tar.gz' "$ROOT/scripts/package-release.sh" \
    || fail "scripts/package-release.sh no longer builds the tarball with git archive; re-check that it carries licenses/"
  echo "third-party notices: licenses/ is tracked and not export-ignored (release tarball = git archive HEAD)"
else
  fail "not a git checkout; cannot prove the release tarball carries licenses/"
fi

# 5. Customers are told where the notices are.
grep -q 'licenses/NOTICE' "$ROOT/README.md" || fail "README.md does not point at licenses/NOTICE"
grep -q 'licenses/NOTICE' "$ROOT/INSTALL.md" || fail "INSTALL.md does not point at licenses/NOTICE"
echo "third-party notices: ok"
