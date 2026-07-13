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
        *) exit 92 ;;
      esac
      if [ "${PRELOAD_DIGEST_MISMATCH:-}" = "$5" ]; then
        digest='sha256:0000000000000000000000000000000000000000000000000000000000000000'
      fi
      printf '%s@%s\n' "${5%%:*}" "$digest"
      printf 'docker image inspect digest %s\n' "$5" >> "$PRELOAD_CALLS"
    else
      exit 92
    fi
    ;;
  pull:*)
    [ "$#" -eq 4 ] && [ "$2" = '--platform' ] && [ "$3" = 'linux/arm64' ] || exit 93
    printf 'docker pull --platform %s %s\n' "$3" "$4" >> "$PRELOAD_CALLS"
    ;;
  image:save)
    [ "$#" -eq 7 ] && [ "$3" = '--platform' ] && [ "$4" = 'linux/arm64' ] && [ "$5" = '--output' ] || exit 94
    case "$6" in "$PRELOAD_ARCHIVE_DIR"/image-[0-9]*.tar) ;; *) exit 95 ;; esac
    [ ! -e "$6" ] || exit 96
    if find "$PRELOAD_ARCHIVE_DIR" -type f -print -quit | grep -q .; then exit 97; fi
    printf '%s' archive > "$6"
    printf 'docker image save --platform %s %s\n' "$4" "$7" >> "$PRELOAD_CALLS"
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
  grep -Fxq "docker image save --platform linux/arm64 $image" "$CALLS" \
    || { echo "image was not saved for the disposable Kind platform: $image" >&2; exit 1; }
done < "$IMAGE_LIST"

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
