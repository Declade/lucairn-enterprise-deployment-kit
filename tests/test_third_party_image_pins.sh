#!/usr/bin/env bash
# test_third_party_image_pins.sh — every third-party container image the kit
# ships is pinned by digest, and the digest is the one image-manifest.yaml
# records (kit 2.0 PRD row 9: "0 kit refs to postgres:/redis: without
# @sha256; live digest gate green").
#
# Why: a tag such as postgres:16-alpine or redis:7-alpine moves whenever
# upstream rebuilds it. Before kit 2.0 the manifest recorded the digest (and
# the live digest gate watched it), but most Compose services and Helm
# templates pulled the bare tag, so an install got whatever bytes the tag
# pointed at that day. Now every reference carries the recorded digest, and
# this check keeps it that way:
#
#   * Compose: every service `image:` of every shipped Compose file (the root
#     docker-compose*.yml and contrib/**/docker-compose*.yml), with
#     ${VAR:-default} interpolation resolved to its default.
#   * Helm: every `image:` in the rendered chart (default values + the shipped
#     overlays values-dev / values-test / values-proof / values-prod + site
#     example, with the optional backup CronJobs and the dashboard on), and
#     every repository/tag[/digest] block and plain `image:` string in the
#     chart's values files (catches defaults a render does not reach).
#   * YAML examples under docs/ (e.g. docs/cni-probe-job.yaml).
#   * Scripts, the CLI, the Makefile, env examples and CI workflows: any
#     reference to a repository the manifest records (plus postgres and redis
#     always) in code, i.e. outside full-line comments.
#
# A third-party reference passes only when it carries `@sha256:<64 hex>` AND
# that digest equals the digest image-manifest.yaml records for the same
# `repo:tag`. A digest-pinned reference the manifest does not record fails
# too: the live digest gate (tests/live_digest_gate.sh) only watches recorded
# refs. First-party images (ghcr.io/declade/…) are out of scope here — the
# doctor's signed-digest checks cover them — and so are images the kit builds
# itself (a Compose service with `build:` and a bare local name).
#
# ONE named exception, read from the manifest rather than listed here: the
# operator-selected inference runtimes of docker-compose.self-hosted.yml
# (image_digests.runtime, `pending: true`: llama.cpp :server, vLLM / TGI
# :latest). The manifest records them as "pin at the digest-pin ceremony to
# the digest the customer deploys" and doctor --strict refuses an unpinned
# override; they are counted and printed, never silently passed. postgres,
# redis and migrate can never use it.
#
# Needs python3 + PyYAML and helm (the Kit test harness installs both); fails
# closed without them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

die() { echo "third-party image pins: FAIL: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is required"
python3 -c 'import yaml' 2>/dev/null || die "PyYAML is required (python3-yaml); a skipped pin check reads as a pass"
command -v helm >/dev/null 2>&1 || die "helm is required to render the chart"

WK="$(mktemp -d)"
trap 'rm -rf "$WK"' EXIT

CHART="$(lucairn_released_chart "$WK/chart")" || die "could not build the released-chart copy"

COMMON=(
  "${HELM_TEST_SECRET_ARGS[@]}"
  --set global.skipPullSecretGuard=true
  --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}"
)
OPTIONAL_ON=(
  --set backup.enabled=true
  --set backup.s3.bucket=lucairn-backups
  --set backup.s3.accessKeySecretRef.name=lucairn-backup-s3
  --set backup.s3.secretKeySecretRef.name=lucairn-backup-s3
  --set backup.encryption.recipientSecretRef.name=lucairn-backup-age
  --set dashboard.enabled=true
)

renders=()
render() {
  local name="$1"; shift
  local out="$WK/render-$name.yaml"
  helm template lucairn "$CHART" "$@" >"$out" 2>"$WK/render-$name.err" \
    || { cat "$WK/render-$name.err" >&2; die "helm render '$name' failed"; }
  renders+=("$out")
}
render default "${COMMON[@]}" "${OPTIONAL_ON[@]}"
render dev -f "$CHART/values-dev.yaml" "${COMMON[@]}" "${OPTIONAL_ON[@]}"
render test -f "$CHART/values-test.yaml" "${COMMON[@]}"
render proof -f "$CHART/values-proof.yaml" "${COMMON[@]}"
render prod -f "$CHART/values-prod.yaml" -f "$CHART/values-prod-site.example.yaml" \
  --set global.skipPullSecretGuard=true

python3 - "$ROOT" "${renders[@]}" <<'PY'
import os, re, subprocess, sys
import yaml

root, renders = sys.argv[1], sys.argv[2:]
DIGEST = re.compile(r"\Asha256:[0-9a-f]{64}\Z")
FIRST_PARTY = ("ghcr.io/declade/",)
NEVER_EXEMPT = ("postgres", "redis", "migrate/migrate")
problems, checked, exempt = [], 0, []

# --- what the manifest records -------------------------------------------
manifest = yaml.safe_load(open(os.path.join(root, "image-manifest.yaml")))
recorded, pending = {}, {}
def collect(group, node):
    for key, value in node.items():
        if not isinstance(value, dict):
            continue
        if "ref" in value:
            ref = value["ref"]
            if ref in recorded or ref in pending:
                problems.append(f"image-manifest.yaml records {ref} twice")
            if value.get("pending") is True:
                pending[ref] = group
            elif isinstance(value.get("digest"), str) and DIGEST.match(value["digest"]):
                recorded[ref] = value["digest"]
        else:
            collect(key if group is None else group, value)
collect(None, manifest["image_digests"])

def short(ref):
    for prefix in ("docker.io/library/", "docker.io/", "index.docker.io/library/"):
        if ref.startswith(prefix):
            return ref[len(prefix):]
    return ref

def repo_of(ref):
    # repo:tag -> repo (a registry port has a / after it)
    head, _, tail = ref.rpartition(":")
    return head if head and "/" not in tail else ref

third_party_repos = {repo_of(r) for r in list(recorded) + list(pending)
                     if not r.startswith(FIRST_PARTY) and "://" not in r}
third_party_repos.update({"postgres", "redis"})

def check(raw, where):
    """Judge one image reference."""
    global checked
    ref = short(raw.strip())
    if not ref or ref.startswith(FIRST_PARTY):
        return
    if "/" not in ref.split("@")[0] and ref.startswith(("dsa-", "lucairn-")):
        return  # a first-party image the chart prefixes with global.imageRegistry
    checked += 1
    name, at, digest = ref.partition("@")
    if ":" not in name.rpartition("/")[2]:
        problems.append(f"{where}: {raw} has no tag (an implicit :latest)")
        return
    if at:
        if not DIGEST.match(digest):
            problems.append(f"{where}: {raw} carries a malformed digest")
        elif name not in recorded:
            problems.append(f"{where}: {raw} is digest-pinned but image-manifest.yaml does not record {name} (the live digest gate cannot watch it)")
        elif recorded[name] != digest:
            problems.append(f"{where}: {raw} pins {digest}, image-manifest.yaml records {recorded[name]} for {name}")
        return
    if pending.get(name) == "runtime" and repo_of(name) not in NEVER_EXEMPT:
        exempt.append(f"{where}: {name}")
        return
    problems.append(f"{where}: {raw} is not pinned by digest (expected {name}@{recorded.get(name, '<a digest image-manifest.yaml records>')})")

# --- Compose ---------------------------------------------------------------
INTERP = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-?+])((?:[^{}]|\{[^{}]*\})*))?\}")
def defaults(value):
    def sub(match):
        op, word = match.group(2), match.group(3)
        if op in (":-", "-"):
            return defaults(word or "")
        return "${" + match.group(1) + "}"   # required / unset: stays a variable
    return INTERP.sub(sub, value)

compose_files = sorted(
    [os.path.join(root, f) for f in os.listdir(root) if re.fullmatch(r"docker-compose.*\.ya?ml", f)]
    + [os.path.join(dp, f) for dp, _, fs in os.walk(os.path.join(root, "contrib"))
       for f in fs if re.fullmatch(r"docker-compose.*\.ya?ml", f)])
for path in compose_files:
    rel = os.path.relpath(path, root)
    services = (yaml.safe_load(open(path)) or {}).get("services") or {}
    for svc, spec in services.items():
        image = (spec or {}).get("image")
        if not isinstance(image, str):
            continue
        value = defaults(image)
        if "${" in value.split("@")[0]:
            problems.append(f"{rel} service {svc}: image {image} has no default to check")
            continue
        if "build" in spec and "/" not in value and "." not in value.split(":")[0]:
            continue  # built by the kit itself
        check(value, f"{rel} service {svc}")

# --- Helm: rendered images -------------------------------------------------
def images_in(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "image" and isinstance(value, str):
                yield value
            else:
                yield from images_in(value)
    elif isinstance(node, list):
        for item in node:
            yield from images_in(item)

for path in renders:
    label = os.path.basename(path)[len("render-"):-len(".yaml")]
    for doc in yaml.safe_load_all(open(path)):
        if not isinstance(doc, dict):
            continue
        where = f"helm render ({label}) {doc.get('kind')}/{(doc.get('metadata') or {}).get('name')}"
        for image in images_in(doc):
            check(image, where)

# --- Helm values + docs YAML (defaults a render does not reach) ------------
def walk_values(node, where):
    if isinstance(node, dict):
        repo, tag = node.get("repository"), node.get("tag")
        if isinstance(repo, str) and repo and not repo.startswith(FIRST_PARTY) and isinstance(tag, (str, int, float)) and str(tag):
            digest = node.get("digest") or ""
            check(f"{repo}:{tag}" + (f"@{digest}" if digest else ""), where)
        for key, value in node.items():
            if key == "image" and isinstance(value, str):
                check(value, where)
            else:
                walk_values(value, f"{where}.{key}")
    elif isinstance(node, list):
        for i, item in enumerate(node):
            walk_values(item, f"{where}[{i}]")

value_files = [os.path.join(dp, f) for dp, _, fs in os.walk(os.path.join(root, "charts"))
               for f in fs if re.fullmatch(r"values.*\.ya?ml", f)]
value_files += [os.path.join(root, "docs", f) for f in os.listdir(os.path.join(root, "docs"))
                if f.endswith((".yaml", ".yml"))]
for path in sorted(value_files):
    rel = os.path.relpath(path, root)
    for doc in yaml.safe_load_all(open(path)):
        walk_values(doc, rel)

# --- scripts, CLI, Makefile, env examples, CI ------------------------------
tracked = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True)
files = tracked.stdout.split() if tracked.returncode == 0 else [
    os.path.relpath(os.path.join(dp, f), root) for dp, _, fs in os.walk(root) for f in fs]
SKIP_PREFIX = ("tests/", "charts/", "licenses/", ".git/", "apps/dashboard/node_modules/")
# Prose and front-end/Go sources: `alpine:init` is an Alpine.js event, not an image.
SKIP_SUFFIX = (".md", ".js", ".css", ".html", ".svg", ".go", ".mod", ".sum", ".png", ".ico")
SKIP_FILES = {"image-manifest.yaml", "apps/dashboard/image-manifest.yaml", "NOTICE", "LICENSE"}
repos = "|".join(sorted((re.escape(r) for r in third_party_repos), key=len, reverse=True))
TEXT_REF = re.compile(r"(?:^|(?<=[\s\"'=(]))((?:docker\.io/(?:library/)?)?(?:" + repos + r")"
                      r":[A-Za-z0-9][A-Za-z0-9._-]*(?:@[A-Za-z0-9:]+)?)(?![/?\w])")
for rel in files:
    if rel.startswith(SKIP_PREFIX) or rel in SKIP_FILES or rel.endswith(SKIP_SUFFIX):
        continue
    if os.path.basename(rel).startswith("docker-compose") and rel.endswith((".yml", ".yaml")):
        continue  # parsed above
    path = os.path.join(root, rel)
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith(("#", "//")):
            continue
        for match in TEXT_REF.finditer(line):
            check(match.group(1), f"{rel}:{n}")

for line in exempt:
    print(f"third-party image pins: exempt (operator-selected runtime, image_digests.runtime pending): {line}")
if checked == 0:
    problems.append("no third-party image reference was found at all; the scan is broken")
if problems:
    for p in problems:
        print(f"third-party image pins: FAIL: {p}", file=sys.stderr)
    print(f"third-party image pins: {len(problems)} problem(s) in {checked} reference(s)", file=sys.stderr)
    sys.exit(1)
print(f"third-party image pins: ok ({checked} references digest-pinned to image-manifest.yaml, {len(exempt)} operator-runtime exceptions)")
PY
