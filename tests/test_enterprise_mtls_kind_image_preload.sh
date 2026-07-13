#!/usr/bin/env bash
set -euo pipefail

# Offline contract for the Kind image preloader. Docker and Kind are local
# doubles: this proves image discovery is based only on renderable PodSpecs,
# test-hook images are excluded, every image is digest-validated before any
# archive save/import, and each discovered image is exported for the disposable
# node platform then loaded through Kind's all-node archive operation.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRELOAD="$ROOT/scripts/preload-enterprise-mtls-kind-images.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

[ -x "$PRELOAD" ] || {
  echo "missing executable Kind image preloader: $PRELOAD" >&2
  exit 1
}

MANIFEST="$TMPDIR/rendered.yaml"
cat > "$MANIFEST" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
spec:
  template:
    spec:
      initContainers:
        - name: migrate-copy
          image: ghcr.io/declade/dsa-gateway:0.5.4
      containers:
        - name: gateway
          image: ghcr.io/declade/dsa-gateway:0.5.4
        - name: sanitizer
          image: ghcr.io/declade/dsa-sanitizer:0.5.4
---
apiVersion: batch/v1
kind: Job
metadata:
  name: id-bridge-migrate-r1
spec:
  template:
    spec:
      containers:
        - name: migrate
          image: migrate/migrate:v4.17.0
---
apiVersion: batch/v1
kind: Job
metadata:
  name: install-hook
  annotations:
    helm.sh/hook: pre-install
spec:
  template:
    spec:
      containers:
        - name: install
          image: postgres:16-alpine
---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: future-controller
spec:
  template:
    spec:
      containers:
        - name: workload
          image: ghcr.io/declade/dsa-veil-witness:0.5.4
---
apiVersion: batch/v1
kind: Job
metadata:
  name: chart-test
  annotations:
    helm.sh/hook: test
spec:
  template:
    spec:
      containers:
        - name: test
          image: should-not-be-loaded:latest
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: unrelated
data:
  image: should-not-be-loaded:either
YAML

FAKE_BIN="$TMPDIR/fake-bin"
CALLS="$TMPDIR/calls"
ARCHIVES_DURING_LOAD="$TMPDIR/archives-during-load"
ARCHIVE_DIR="$TMPDIR/preload-archives"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:${2:-}" in
  inspect:--format)
    [ "$#" -eq 4 ] && [ "$3" = '{{.Image}}' ] && [ "$4" = 'preload-test-control-plane' ] || exit 91
    printf '%s\n' 'sha256:preload-test-node'
    printf 'docker inspect %s\n' "$4" >> "$PRELOAD_CALLS"
    ;;
  image:inspect)
    if [ "$#" -eq 5 ] && [ "$3" = '--format' ] && [ "$4" = '{{.Os}}/{{.Architecture}}' ] && [ "$5" = 'sha256:preload-test-node' ]; then
      printf '%s\n' 'linux/arm64'
      printf 'docker image inspect %s\n' "$5" >> "$PRELOAD_CALLS"
    elif [ "$#" -eq 5 ] && [ "$3" = '--format' ] && [ "$4" = '{{range .RepoDigests}}{{println .}}{{end}}' ]; then
      case "$5" in
        ghcr.io/declade/dsa-gateway:0.5.4) digest='sha256:f73e55e0a3d3445d3242d2a73aff7086427da50cbcd2e47e3c8cd4f0fad2bece' ;;
        ghcr.io/declade/dsa-sanitizer:0.5.4) digest='sha256:5204d30b1cd4ae12ec2faf47eaf7a4f9fdfaf5137c37cb625752f96452eea9df' ;;
        ghcr.io/declade/dsa-veil-witness:0.5.4) digest='sha256:edc110fd5f827604790cee2be4a963ad03ee7201cbfb1262d2b23ff95a500523' ;;
        migrate/migrate:v4.17.0) digest='sha256:4d017c6fb5997127093648cab09e63d377997125c3d3dcca18e5d1c847da49fa' ;;
        postgres:16-alpine) digest='sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777' ;;
        sha256:1111111111111111111111111111111111111111111111111111111111111111) digest='sha256:f73e55e0a3d3445d3242d2a73aff7086427da50cbcd2e47e3c8cd4f0fad2bece' ;;
        sha256:2222222222222222222222222222222222222222222222222222222222222222) digest='sha256:5204d30b1cd4ae12ec2faf47eaf7a4f9fdfaf5137c37cb625752f96452eea9df' ;;
        sha256:3333333333333333333333333333333333333333333333333333333333333333) digest='sha256:edc110fd5f827604790cee2be4a963ad03ee7201cbfb1262d2b23ff95a500523' ;;
        sha256:4444444444444444444444444444444444444444444444444444444444444444) digest='sha256:4d017c6fb5997127093648cab09e63d377997125c3d3dcca18e5d1c847da49fa' ;;
        sha256:5555555555555555555555555555555555555555555555555555555555555555) digest='sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777' ;;
        sha256:6666666666666666666666666666666666666666666666666666666666666666) digest='sha256:0000000000000000000000000000000000000000000000000000000000000000' ;;
        *) exit 92 ;;
      esac
      if [ "${PRELOAD_DIGEST_MISMATCH:-}" = "$5" ]; then
        digest='sha256:0000000000000000000000000000000000000000000000000000000000000000'
      fi
      if [ "${PRELOAD_RETARGET_TAG_BEFORE_ID:-}" = "$5" ]; then
        : > "$PRELOAD_INITIAL_TAG_DIGEST_VALIDATED"
      fi
      printf '%s@%s\n' "${5%%:*}" "$digest"
      printf 'docker image inspect digest %s\n' "$5" >> "$PRELOAD_CALLS"
    elif [ "$#" -eq 5 ] && [ "$3" = '--format' ] && [ "$4" = '{{.Id}}' ]; then
      case "$5" in
        ghcr.io/declade/dsa-gateway:0.5.4) image_id='sha256:1111111111111111111111111111111111111111111111111111111111111111' ;;
        ghcr.io/declade/dsa-sanitizer:0.5.4) image_id='sha256:2222222222222222222222222222222222222222222222222222222222222222' ;;
        ghcr.io/declade/dsa-veil-witness:0.5.4) image_id='sha256:3333333333333333333333333333333333333333333333333333333333333333' ;;
        migrate/migrate:v4.17.0) image_id='sha256:4444444444444444444444444444444444444444444444444444444444444444' ;;
        postgres:16-alpine) image_id='sha256:5555555555555555555555555555555555555555555555555555555555555555' ;;
        *) exit 92 ;;
      esac
      if [ "${PRELOAD_RETARGET_TAG_BEFORE_ID:-}" = "$5" ]; then
        [ -e "$PRELOAD_INITIAL_TAG_DIGEST_VALIDATED" ] || exit 101
        : > "$PRELOAD_TAG_RETARGETED_BEFORE_ID"
        image_id='sha256:6666666666666666666666666666666666666666666666666666666666666666'
      fi
      if [ "${PRELOAD_SUBSTITUTE_TAGS_AFTER_INSPECT:-}" = "1" ]; then
        : > "$PRELOAD_TAGS_SUBSTITUTED"
      fi
      printf '%s\n' "$image_id"
      printf 'docker image inspect ID %s\n' "$5" >> "$PRELOAD_CALLS"
    else
      exit 92
    fi
    ;;
  pull:*)
    [ "$#" -eq 4 ] && [ "$2" = '--platform' ] && [ "$3" = 'linux/arm64' ] || exit 93
    printf 'docker pull --platform %s %s\n' "$3" "$4" >> "$PRELOAD_CALLS"
    ;;
  image:save)
    [ "$#" -eq 8 ] && [ "$3" = '--platform' ] && [ "$4" = 'linux/arm64' ] && [ "$5" = '--output' ] || exit 94
    case "$6" in "$PRELOAD_ARCHIVE_DIR"/image-[0-9]*.tar) ;; *) exit 95 ;; esac
    [ ! -e "$6" ] || exit 96
    if find "$PRELOAD_ARCHIVE_DIR" -type f -print -quit | grep -q .; then exit 97; fi
    case "$7" in sha256:1111111111111111111111111111111111111111111111111111111111111111|sha256:2222222222222222222222222222222222222222222222222222222222222222|sha256:3333333333333333333333333333333333333333333333333333333333333333|sha256:4444444444444444444444444444444444444444444444444444444444444444|sha256:5555555555555555555555555555555555555555555555555555555555555555) ;; *) exit 99 ;; esac
    case "$8" in ghcr.io/declade/dsa-gateway:0.5.4|ghcr.io/declade/dsa-sanitizer:0.5.4|ghcr.io/declade/dsa-veil-witness:0.5.4|migrate/migrate:v4.17.0|postgres:16-alpine) ;; *) exit 100 ;; esac
    # Docker Desktop/containerd may report an OCI index as .Id while save
    # writes a selected-platform config. Keep those values distinct in every
    # accepted fixture.
    config_id='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    ARCHIVE="$6" RUNTIME_TAG="$8" CONFIG_ID="$config_id" ARCHIVE_LEGACY_CONFIG="${PRELOAD_ARCHIVE_LEGACY_CONFIG:-}" ARCHIVE_VARIANT="${PRELOAD_ARCHIVE_VARIANT:-}" PRELOAD_ARCHIVE_TAG_RETARGETED="${PRELOAD_ARCHIVE_TAG_RETARGETED:-}" ruby -rjson -rrubygems/package -e '
      config = ENV.fetch("CONFIG_ID").delete_prefix("sha256:")
      config_path = if ENV.fetch("ARCHIVE_LEGACY_CONFIG", "") == "1"
        "#{config}.json"
      else
        "blobs/sha256/#{config}"
      end
      entry = {
        "Config" => config_path,
        "RepoTags" => [ENV.fetch("RUNTIME_TAG")],
        "Layers" => []
      }
      entries = [entry]
      if ENV.fetch("PRELOAD_ARCHIVE_TAG_RETARGETED", "") == "1"
        # Saving a captured ID plus a tag that was retargeted after inspect
        # yields an ID-only entry and a separately tagged current image.
        entries = [
          entry.merge("RepoTags" => nil),
          entry.merge("Config" => "blobs/sha256/#{"b" * 64}")
        ]
      else
        case ENV.fetch("ARCHIVE_VARIANT", "")
        when "missing-tag"
          entry["RepoTags"] = []
        when "duplicate-tag"
          entries << entry.dup
        when "conflicting-tags"
          entry["RepoTags"] << "conflicting.example.invalid:tag"
        when "malformed-config"
          entry["Config"] = "not-a-docker-config-path"
        when ""
        else
          abort "unknown archive test variant"
        end
      end
      manifest = JSON.generate(entries)
      File.open(ENV.fetch("ARCHIVE"), "wb") do |file|
        Gem::Package::TarWriter.new(file) do |tar|
          tar.add_file_simple("manifest.json", 0o644, manifest.bytesize) { |entry| entry.write(manifest) }
        end
      end
    '
    printf 'docker image save --platform %s %s %s\n' "$4" "$7" "$8" >> "$PRELOAD_CALLS"
    ;;
  *) exit 98 ;;
esac
DOCKER
cat > "$FAKE_BIN/kind" <<'KIND'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:${2:-}" in
  get:nodes)
    [ "${3:-}" = "--name" ] && [ "${4:-}" = "preload-test" ] || exit 93
    printf '%s\n' preload-test-control-plane preload-test-worker preload-test-worker2
    ;;
  load:image-archive)
    [ "${3:-}" = "--name" ] && [ "${4:-}" = "preload-test" ] && [ "$#" -eq 5 ] && [ -s "$5" ] || exit 94
    case "$5" in "$PRELOAD_ARCHIVE_DIR"/image-[0-9]*.tar) ;; *) exit 95 ;; esac
    printf '%s\n' "$5" >> "$PRELOAD_ARCHIVES_DURING_LOAD"
    printf 'kind load image-archive --name %s\n' "$4" >> "$PRELOAD_CALLS"
    ;;
  *) exit 96 ;;
esac
KIND
chmod 0700 "$FAKE_BIN/docker" "$FAKE_BIN/kind"

IMAGE_LIST="$TMPDIR/images.txt"
TAGS_SUBSTITUTED="$TMPDIR/tags-substituted"
MISMATCH_CALLS="$TMPDIR/mismatch-calls"
MISMATCH_ARCHIVE_DIR="$TMPDIR/mismatch-archives"
if PATH="$FAKE_BIN:$PATH" PRELOAD_CALLS="$MISMATCH_CALLS" \
  PRELOAD_ARCHIVE_DIR="$MISMATCH_ARCHIVE_DIR" PRELOAD_ARCHIVES_DURING_LOAD="$ARCHIVES_DURING_LOAD" \
  PRELOAD_DIGEST_MISMATCH='ghcr.io/declade/dsa-gateway:0.5.4' "$PRELOAD" \
  --cluster preload-test \
  --rendered-manifest "$MANIFEST" \
  --image-list "$TMPDIR/mismatch-images.txt" \
  --archive-dir "$MISMATCH_ARCHIVE_DIR" \
  >"$TMPDIR/mismatch.stdout" 2>"$TMPDIR/mismatch.stderr"; then
  echo "Kind image preloader accepted a tag re-targeted digest" >&2
  exit 1
fi
grep -Fq 'digest mismatch or unresolved content: ghcr.io/declade/dsa-gateway:0.5.4' "$TMPDIR/mismatch.stderr" \
  || { cat "$TMPDIR/mismatch.stderr" >&2; echo "Kind image preloader did not identify the tag re-target" >&2; exit 1; }
if grep -Eq 'docker image save|kind load image-archive' "$MISMATCH_CALLS"; then
  echo "Kind image preloader saved or imported before rejecting a digest mismatch" >&2
  exit 1
fi
[ ! -e "$MISMATCH_ARCHIVE_DIR" ] \
  || { echo "Kind image preloader left an archive directory after digest mismatch" >&2; exit 1; }

# A runtime tag can move after its initial RepoDigests validation and before
# Docker returns .Id. The captured replacement ID must be checked directly,
# rejecting the changed content before any archive is saved or imported.
PRE_ID_RETARGET_CALLS="$TMPDIR/pre-id-retarget-calls"
PRE_ID_RETARGET_ARCHIVE_DIR="$TMPDIR/pre-id-retarget-archives"
PRE_ID_INITIAL_TAG_DIGEST_VALIDATED="$TMPDIR/pre-id-initial-tag-digest-validated"
PRE_ID_TAG_RETARGETED="$TMPDIR/pre-id-tag-retargeted"
if PATH="$FAKE_BIN:$PATH" PRELOAD_CALLS="$PRE_ID_RETARGET_CALLS" \
  PRELOAD_ARCHIVE_DIR="$PRE_ID_RETARGET_ARCHIVE_DIR" PRELOAD_ARCHIVES_DURING_LOAD="$TMPDIR/pre-id-retarget-loads" \
  PRELOAD_RETARGET_TAG_BEFORE_ID='ghcr.io/declade/dsa-gateway:0.5.4' \
  PRELOAD_INITIAL_TAG_DIGEST_VALIDATED="$PRE_ID_INITIAL_TAG_DIGEST_VALIDATED" \
  PRELOAD_TAG_RETARGETED_BEFORE_ID="$PRE_ID_TAG_RETARGETED" "$PRELOAD" \
  --cluster preload-test \
  --rendered-manifest "$MANIFEST" \
  --image-list "$TMPDIR/pre-id-retarget-images.txt" \
  --archive-dir "$PRE_ID_RETARGET_ARCHIVE_DIR" \
  >"$TMPDIR/pre-id-retarget.stdout" 2>"$TMPDIR/pre-id-retarget.stderr"; then
  echo "Kind image preloader accepted a replacement ID after tag validation" >&2
  exit 1
fi
[ -e "$PRE_ID_INITIAL_TAG_DIGEST_VALIDATED" ] && [ -e "$PRE_ID_TAG_RETARGETED" ] \
  || { echo "Kind image preloader pre-ID retarget regression did not retarget after tag validation" >&2; exit 1; }
grep -Fq 'digest mismatch or unresolved content: sha256:6666666666666666666666666666666666666666666666666666666666666666' "$TMPDIR/pre-id-retarget.stderr" \
  || { cat "$TMPDIR/pre-id-retarget.stderr" >&2; echo "Kind image preloader did not reject the replacement immutable ID" >&2; exit 1; }
if grep -Eq 'docker image save|kind load image-archive' "$PRE_ID_RETARGET_CALLS"; then
  echo "Kind image preloader saved or imported after a pre-ID tag re-target" >&2
  exit 1
fi
[ ! -e "$PRE_ID_RETARGET_ARCHIVE_DIR" ] \
  || { echo "Kind image preloader left an archive directory after pre-ID tag re-target" >&2; exit 1; }

if ! PATH="$FAKE_BIN:$PATH" PRELOAD_CALLS="$CALLS" \
  PRELOAD_ARCHIVE_DIR="$ARCHIVE_DIR" PRELOAD_ARCHIVES_DURING_LOAD="$ARCHIVES_DURING_LOAD" "$PRELOAD" \
  --cluster preload-test \
  --rendered-manifest "$MANIFEST" \
  --image-list "$IMAGE_LIST" \
  --archive-dir "$ARCHIVE_DIR" \
  >"$TMPDIR/preload.stdout" 2>"$TMPDIR/preload.stderr"; then
  cat "$TMPDIR/preload.stderr" >&2
  exit 1
fi

[ ! -s "$TMPDIR/preload.stdout" ] || {
  echo "Kind image preloader must keep its derived list in the requested file" >&2
  exit 1
}
grep -Fq 'loaded 5 rendered topology image(s) into all 3 node(s) of preload-test' "$TMPDIR/preload.stderr" \
  || { echo "Kind image preloader did not report all-node preload" >&2; exit 1; }

# Docker also has a legacy archive config path form (<hex>.json). Accept it
# when the sole manifest entry carries the required runtime tag.
LEGACY_CALLS="$TMPDIR/legacy-calls"
LEGACY_ARCHIVES="$TMPDIR/legacy-archives-during-load"
LEGACY_ARCHIVE_DIR="$TMPDIR/legacy-archives"
if ! PATH="$FAKE_BIN:$PATH" PRELOAD_CALLS="$LEGACY_CALLS" \
  PRELOAD_ARCHIVE_DIR="$LEGACY_ARCHIVE_DIR" PRELOAD_ARCHIVES_DURING_LOAD="$LEGACY_ARCHIVES" \
  PRELOAD_ARCHIVE_LEGACY_CONFIG=1 "$PRELOAD" \
  --cluster preload-test \
  --rendered-manifest "$MANIFEST" \
  --image-list "$TMPDIR/legacy-images.txt" \
  --archive-dir "$LEGACY_ARCHIVE_DIR" \
  >"$TMPDIR/legacy.stdout" 2>"$TMPDIR/legacy.stderr"; then
  cat "$TMPDIR/legacy.stderr" >&2
  echo "Kind image preloader rejected a legacy config path with a matching tag binding" >&2
  exit 1
fi
[ "$(wc -l < "$LEGACY_ARCHIVES" | tr -d ' ')" = "5" ] \
  || { echo "Kind image preloader did not load every accepted legacy archive" >&2; exit 1; }
[ ! -e "$LEGACY_ARCHIVE_DIR" ] \
  || { echo "Kind image preloader left legacy platform archives behind" >&2; exit 1; }

printf '%s\n' \
  ghcr.io/declade/dsa-gateway:0.5.4 \
  ghcr.io/declade/dsa-sanitizer:0.5.4 \
  ghcr.io/declade/dsa-veil-witness:0.5.4 \
  migrate/migrate:v4.17.0 \
  postgres:16-alpine \
  > "$TMPDIR/expected-images"
diff -u "$TMPDIR/expected-images" "$IMAGE_LIST"

while IFS= read -r image; do
  grep -Fxq "docker pull --platform linux/arm64 $image" "$CALLS" \
    || { echo "image was not pulled before Kind load: $image" >&2; exit 1; }
done < "$IMAGE_LIST"

# The fake Docker daemon substitutes every rendered tag immediately after its
# local immutable ID is inspected. The preloader must request one archive with
# both the captured ID and the required tag, then accept the single tagged
# manifest entry even when its platform config differs from the index .Id.
if ! PATH="$FAKE_BIN:$PATH" PRELOAD_CALLS="$TMPDIR/substitution-calls" \
  PRELOAD_ARCHIVE_DIR="$TMPDIR/substitution-archives" PRELOAD_ARCHIVES_DURING_LOAD="$TMPDIR/substitution-loads" \
  PRELOAD_SUBSTITUTE_TAGS_AFTER_INSPECT=1 PRELOAD_TAGS_SUBSTITUTED="$TAGS_SUBSTITUTED" "$PRELOAD" \
  --cluster preload-test \
  --rendered-manifest "$MANIFEST" \
  --image-list "$TMPDIR/substitution-images.txt" \
  --archive-dir "$TMPDIR/substitution-archives" \
  >"$TMPDIR/substitution.stdout" 2>"$TMPDIR/substitution.stderr"; then
  cat "$TMPDIR/substitution.stderr" >&2
  exit 1
fi
[ -e "$TAGS_SUBSTITUTED" ] || {
  echo "Kind image preloader substitution regression did not retag after inspect" >&2
  exit 1
}
if grep -Eq 'docker image save --platform linux/arm64 (ghcr.io/|migrate/|postgres:)' "$TMPDIR/substitution-calls"; then
  echo "Kind image preloader saved a mutable tag after substitution" >&2
  exit 1
fi
while IFS= read -r image; do
  grep -Eq "^docker image save --platform linux/arm64 sha256:[1-5]{64} ${image}$" "$TMPDIR/substitution-calls" \
    || { echo "Kind image preloader did not save captured ID plus runtime tag after substitution: $image" >&2; exit 1; }
done < "$TMPDIR/substitution-images.txt"

# A later tag substitution makes Docker save two entries: the captured ID-only
# image and the changed tag's image with another config. That must fail before
# the first Kind import, even though the captured ID remains in the request.
ARCHIVE_MISMATCH_CALLS="$TMPDIR/archive-mismatch-calls"
ARCHIVE_MISMATCH_DIR="$TMPDIR/archive-mismatch-archives"
ARCHIVE_MISMATCH_TAGS="$TMPDIR/archive-mismatch-tags-substituted"
if PATH="$FAKE_BIN:$PATH" PRELOAD_CALLS="$ARCHIVE_MISMATCH_CALLS" \
  PRELOAD_ARCHIVE_DIR="$ARCHIVE_MISMATCH_DIR" PRELOAD_ARCHIVES_DURING_LOAD="$TMPDIR/archive-mismatch-loads" \
  PRELOAD_SUBSTITUTE_TAGS_AFTER_INSPECT=1 PRELOAD_TAGS_SUBSTITUTED="$ARCHIVE_MISMATCH_TAGS" \
  PRELOAD_ARCHIVE_TAG_RETARGETED=1 "$PRELOAD" \
  --cluster preload-test \
  --rendered-manifest "$MANIFEST" \
  --image-list "$TMPDIR/archive-mismatch-images.txt" \
  --archive-dir "$ARCHIVE_MISMATCH_DIR" \
  >"$TMPDIR/archive-mismatch.stdout" 2>"$TMPDIR/archive-mismatch.stderr"; then
  echo "Kind image preloader accepted an archive whose runtime tag changed config after ID capture" >&2
  exit 1
fi
[ -e "$ARCHIVE_MISMATCH_TAGS" ] || {
  echo "Kind image preloader archive mismatch regression did not retag after inspect" >&2
  exit 1
}
grep -Fq 'archive must contain exactly one manifest entry' "$TMPDIR/archive-mismatch.stderr" \
  || { cat "$TMPDIR/archive-mismatch.stderr" >&2; echo "Kind image preloader did not reject the retargeted multi-entry archive" >&2; exit 1; }
grep -Eq '^docker image save --platform linux/arm64 sha256:1111111111111111111111111111111111111111111111111111111111111111 ghcr.io/declade/dsa-gateway:0.5.4$' "$ARCHIVE_MISMATCH_CALLS" \
  || { echo "Kind image preloader archive mismatch regression did not save captured ID plus runtime tag" >&2; exit 1; }
if grep -Fq 'kind load image-archive' "$ARCHIVE_MISMATCH_CALLS"; then
  echo "Kind image preloader loaded an archive before rejecting its retargeted manifest" >&2
  exit 1
fi
[ ! -e "$ARCHIVE_MISMATCH_DIR" ] \
  || { echo "Kind image preloader left an archive directory after retargeted manifest rejection" >&2; exit 1; }

# The verifier is deliberately strict about every malformed or ambiguous tag
# binding shape that Docker could place in manifest.json. None may reach Kind.
for archive_variant in missing-tag duplicate-tag conflicting-tags malformed-config; do
  variant_calls="$TMPDIR/archive-${archive_variant}-calls"
  variant_dir="$TMPDIR/archive-${archive_variant}-archives"
  if PATH="$FAKE_BIN:$PATH" PRELOAD_CALLS="$variant_calls" \
    PRELOAD_ARCHIVE_DIR="$variant_dir" PRELOAD_ARCHIVES_DURING_LOAD="$TMPDIR/archive-${archive_variant}-loads" \
    PRELOAD_ARCHIVE_VARIANT="$archive_variant" "$PRELOAD" \
    --cluster preload-test \
    --rendered-manifest "$MANIFEST" \
    --image-list "$TMPDIR/archive-${archive_variant}-images.txt" \
    --archive-dir "$variant_dir" \
    >"$TMPDIR/archive-${archive_variant}.stdout" 2>"$TMPDIR/archive-${archive_variant}.stderr"; then
    echo "Kind image preloader accepted $archive_variant archive tag binding" >&2
    exit 1
  fi
  if grep -Fq 'kind load image-archive' "$variant_calls"; then
    echo "Kind image preloader loaded $archive_variant archive before rejecting its tag binding" >&2
    exit 1
  fi
  [ ! -e "$variant_dir" ] \
    || { echo "Kind image preloader left an archive directory after $archive_variant rejection" >&2; exit 1; }
done

grep -Fxq 'docker inspect preload-test-control-plane' "$CALLS" \
  || { echo "Kind preloader did not derive a platform from its disposable node" >&2; exit 1; }
grep -Fxq 'docker image inspect sha256:preload-test-node' "$CALLS" \
  || { echo "Kind preloader did not inspect the disposable node image platform" >&2; exit 1; }
[ "$(wc -l < "$ARCHIVES_DURING_LOAD" | tr -d ' ')" = "5" ] \
  || { echo "every rendered image must be loaded through a bounded archive" >&2; exit 1; }
grep -Fxq 'kind load image-archive --name preload-test' "$CALLS" \
  || { echo "Kind image preloader did not use image-archive for the named cluster" >&2; exit 1; }
[ ! -e "$ARCHIVE_DIR" ] \
  || { echo "Kind image preloader left its platform archives behind" >&2; exit 1; }

if grep -Fq 'should-not-be-loaded' "$CALLS"; then
  echo "Kind image preloader must ignore Helm test hooks and non-PodSpec values" >&2
  exit 1
fi

echo "enterprise mTLS Kind image-preload contract: ok"
