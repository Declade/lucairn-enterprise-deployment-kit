#!/usr/bin/env bash
set -euo pipefail

# Preload the exact Pod images in a Helm render into every node of one Kind
# cluster. The caller supplies the render produced with the same values used
# for `helm upgrade --install`; this keeps the image set coupled to the
# rendered mandatory topology rather than to a hand-maintained image list.

usage() {
  echo "usage: $0 --cluster <kind-cluster> --rendered-manifest <manifest.yaml> --image-list <images.txt> --archive-dir <state-dir>" >&2
}

CLUSTER=""
RENDERED_MANIFEST=""
IMAGE_LIST=""
ARCHIVE_DIR=""
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_MANIFEST="$ROOT/image-manifest.yaml"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cluster)
      CLUSTER="${2:-}"
      shift 2
      ;;
    --rendered-manifest)
      RENDERED_MANIFEST="${2:-}"
      shift 2
      ;;
    --image-list)
      IMAGE_LIST="${2:-}"
      shift 2
      ;;
    --archive-dir)
      ARCHIVE_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [ -z "$CLUSTER" ] || [ -z "$RENDERED_MANIFEST" ] || [ -z "$IMAGE_LIST" ] || [ -z "$ARCHIVE_DIR" ]; then
  usage
  exit 2
fi
if [ ! -r "$RENDERED_MANIFEST" ]; then
  echo "FAIL: rendered manifest is not readable: $RENDERED_MANIFEST" >&2
  exit 1
fi
if [ ! -r "$IMAGE_MANIFEST" ]; then
  echo "FAIL: repository image manifest is not readable: $IMAGE_MANIFEST" >&2
  exit 1
fi

# The list is intentionally extracted from Kubernetes PodSpecs only. This
# excludes incidental strings in ConfigMaps/Secrets and Helm test hooks, which
# `helm upgrade --install` does not create. Init containers and install hooks
# are included because their images can block a clean install.
ruby -ryaml -e '
  manifest = ARGV.fetch(0)
  images = []

  add_pod_images = lambda do |pod_spec|
    next unless pod_spec.is_a?(Hash)
    %w[initContainers containers].each do |field|
      Array(pod_spec[field]).each do |container|
        image = container.is_a?(Hash) ? container["image"] : nil
        abort "rendered PodSpec contains an empty image" unless image.is_a?(String) && !image.empty?
        images << image
      end
    end
  end

  collect_document = nil
  collect_document = lambda do |document|
    next unless document.is_a?(Hash)
    if document["kind"] == "List"
      Array(document["items"]).each { |item| collect_document.call(item) }
      next
    end
    annotations = document.dig("metadata", "annotations") || {}
    hooks = annotations.fetch("helm.sh/hook", "").split(",").map(&:strip).reject(&:empty?)
    next if !hooks.empty? && hooks.all? { |hook| hook.start_with?("test") }

    # A generic spec.template.spec catches present workload types and any
    # future Pod-template controller without requiring another image list
    # update. CronJobs use jobTemplate, while a direct Pod carries spec itself.
    add_pod_images.call(document.dig("spec", "template", "spec"))
    add_pod_images.call(document.dig("spec", "jobTemplate", "spec", "template", "spec"))
    add_pod_images.call(document["spec"]) if document["kind"] == "Pod"
  end
  YAML.load_stream(File.read(manifest)).compact.each { |document| collect_document.call(document) }

  abort "rendered mandatory topology contains no Pod images" if images.empty?
  puts images.uniq.sort
' "$RENDERED_MANIFEST" > "$IMAGE_LIST"

if [ ! -s "$IMAGE_LIST" ]; then
  echo "FAIL: rendered mandatory topology contains no preloadable images" >&2
  exit 1
fi

node_count=0
platform_node=""
while IFS= read -r node; do
  [ -n "$node" ] || continue
  node_count=$((node_count + 1))
  if [ -z "$platform_node" ]; then
    platform_node="$node"
  fi
done < <(kind get nodes --name "$CLUSTER")
if [ "$node_count" -eq 0 ]; then
  echo "FAIL: disposable Kind cluster has no nodes: $CLUSTER" >&2
  exit 1
fi

# Docker Desktop can retain a local multi-platform index with children that
# are not all present. Kind imports archives with containerd --all-platforms,
# so loading that index directly fails. Read the actual disposable node image
# platform, then export each pulled workload image for that platform only.
node_image="$(docker inspect --format '{{.Image}}' "$platform_node")"
kind_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$node_image")"
case "$kind_platform" in
  linux/*)
    kind_arch="${kind_platform#linux/}"
    case "$kind_arch" in
      ""|*/*|*[!a-z0-9._-]*)
        echo "FAIL: disposable Kind node returned an invalid platform: $kind_platform" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "FAIL: disposable Kind node must use a Linux platform, got: $kind_platform" >&2
    exit 1
    ;;
esac

# The harness supplies a new child of its private state directory. Refusing an
# existing path prevents this utility from deleting unrelated caller files.
if [ -e "$ARCHIVE_DIR" ]; then
  echo "FAIL: preload archive directory must not already exist: $ARCHIVE_DIR" >&2
  exit 1
fi
mkdir -p -- "$ARCHIVE_DIR"
archive=""
cleanup_archive() {
  if [ -n "$archive" ]; then
    rm -f -- "$archive"
  fi
  rmdir -- "$ARCHIVE_DIR" 2>/dev/null || true
}
trap cleanup_archive EXIT

# Return the repository-recorded tag ref and immutable digest for one rendered
# image. A rendered explicit digest is accepted only when it is exactly the
# recorded release digest; a tag-only ref must be recorded too. This lets the
# render remain ergonomic while making the Kind evidence path fail closed.
recorded_image() {
  ruby -ryaml -e '
    manifest = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
    image = ARGV.fetch(1)
    ref, explicit = image.split("@", 2)
    abort "invalid rendered image digest" if explicit && !explicit.match?(/\Asha256:[0-9a-f]{64}\z/)

    entries = []
    walk = lambda do |value|
      case value
      when Hash
        if value.key?("ref") || value.key?("digest")
          entries << value
        end
        value.each_value { |child| walk.call(child) }
      when Array
        value.each { |child| walk.call(child) }
      end
    end
    walk.call(manifest.fetch("image_digests"))
    matches = entries.select { |entry| entry["ref"] == ref }
    abort "rendered image is not recorded by image-manifest.yaml: #{ref}" unless matches.length == 1
    entry = matches.fetch(0)
    digest = entry["digest"]
    abort "recorded image lacks an immutable digest: #{ref}" unless digest.is_a?(String) && digest.match?(/\Asha256:[0-9a-f]{64}\z/)
    abort "rendered image digest differs from image-manifest.yaml: #{image}" if explicit && explicit != digest
    print "#{ref}\t#{digest}"
  ' "$IMAGE_MANIFEST" "$1"
}

# Docker records the immutable content digest(s) attached to the pulled local
# image in RepoDigests. Require the recorded release digest to be present; an
# empty/changed result is a tag re-target or unverifiable pull and must never
# reach docker image save or kind load.
require_recorded_digest() {
  local image="$1" expected_digest="$2" resolved
  resolved="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image")"
  if ! printf '%s\n' "$resolved" | sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\)$/\1/p' | grep -Fxq "$expected_digest"; then
    echo "FAIL: rendered image digest mismatch or unresolved content: $image (expected $expected_digest)" >&2
    exit 1
  fi
}

# `docker image save <image-id>` deliberately emits RepoTags: null. Kind can
# import those bytes, but a rendered Pod using the runtime tag may then fail to
# select the imported image. Save the captured immutable ID together with the
# required runtime tag, then inspect Docker's completed archive before Kind
# sees it. Docker Desktop's containerd image store reports an OCI index digest
# for .Id while save writes the selected platform config, so those digests must
# not be compared. Instead the archive must have exactly one tagged entry;
# accepting an ID-only entry or a tag that moved after capture would make the
# preload evidence diverge from the rendered PodSpec.
require_archive_tag_binding() {
  local archive="$1" runtime_tag="$2" expected_image_id="$3"
  if ! ruby -rjson -rrubygems/package -e '
    archive, runtime_tag, expected_image_id = ARGV
    abort "invalid captured image ID" unless expected_image_id.match?(/\Asha256:[0-9a-f]{64}\z/)
    manifest_json = nil

    File.open(archive, "rb") do |file|
      Gem::Package::TarReader.new(file) do |tar|
        tar.each do |entry|
          next unless entry.full_name == "manifest.json"
          abort "archive has multiple manifest.json entries" if manifest_json
          abort "archive manifest.json is not a regular file" unless entry.file?
          manifest_json = entry.read
        end
      end
    end

    abort "archive is missing manifest.json" unless manifest_json
    manifest = JSON.parse(manifest_json)
    abort "archive manifest is not an array" unless manifest.is_a?(Array)
    abort "archive must contain exactly one manifest entry" unless manifest.length == 1

    entry = manifest.fetch(0)
    abort "archive manifest entry is malformed" unless entry.is_a?(Hash)
    abort "archive has invalid runtime tag binding" unless entry["RepoTags"] == [runtime_tag]
    config = entry["Config"]
    case config
    when /\Ablobs\/sha256\/[0-9a-f]{64}\z/
    when /\A[0-9a-f]{64}\.json\z/
    else
      abort "archive config path is malformed"
    end
  ' "$archive" "$runtime_tag" "$expected_image_id"; then
    echo "FAIL: archive tag binding is invalid: $runtime_tag" >&2
    exit 1
  fi
}

# Validate the full rendered image set before creating a single archive. This
# gives a tag re-target no opportunity to partially populate Kind before the
# preloader rejects the evidence/runtime mismatch. Capture Docker's local
# immutable image ID as part of this validation, then save that ID together
# with the runtime tag and verify the resulting archive binding. Pull a single
# Kind-node platform so Docker Desktop never retains an incomplete
# multi-platform index.
validated_images=()
validated_image_ids=()
while IFS= read -r image; do
  [ -n "$image" ] || continue
  if ! record="$(recorded_image "$image")"; then
    echo "FAIL: rendered topology image is not digest-pinned by the repository: $image" >&2
    exit 1
  fi
  IFS="$(printf '\t')" read -r recorded_ref recorded_digest <<EOF
$record
EOF
  [ "$recorded_ref" = "${image%@*}" ] && [ -n "$recorded_digest" ] || {
    echo "FAIL: malformed repository digest record for rendered image: $image" >&2
    exit 1
  }
  docker pull --platform "$kind_platform" "$image" >/dev/null
  require_recorded_digest "$image" "$recorded_digest"
  local_image_id="$(docker image inspect --format '{{.Id}}' "$image")"
  if ! [[ "$local_image_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "FAIL: rendered image has no immutable local image ID: $image" >&2
    exit 1
  fi
  require_recorded_digest "$local_image_id" "$recorded_digest"
  validated_images+=("$image")
  validated_image_ids+=("$local_image_id")
done < "$IMAGE_LIST"

image_count=0
for index in "${!validated_images[@]}"; do
  image="${validated_images[$index]}"
  local_image_id="${validated_image_ids[$index]}"
  runtime_tag="${image%@*}"
  # Docker reads the caller's existing DOCKER_CONFIG. The harness never copies
  # or prints registry credentials. The archive filename is sequence-based so
  # image names never become filesystem paths. The EXIT trap removes a partial
  # archive if either save or the Kind import fails.
  image_count=$((image_count + 1))
  archive="$ARCHIVE_DIR/image-$image_count.tar"
  docker image save --platform "$kind_platform" --output "$archive" "$local_image_id" "$runtime_tag" >/dev/null
  if [ ! -s "$archive" ]; then
    echo "FAIL: platform-specific image archive is empty: $image" >&2
    exit 1
  fi
  require_archive_tag_binding "$archive" "$runtime_tag" "$local_image_id"
  kind load image-archive --name "$CLUSTER" "$archive" >/dev/null
  rm -f -- "$archive"
  archive=""
done

echo "Kind preload: loaded $image_count rendered topology image(s) into all $node_count node(s) of $CLUSTER." >&2
