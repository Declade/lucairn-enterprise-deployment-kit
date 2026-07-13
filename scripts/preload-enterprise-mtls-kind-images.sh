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

image_count=0
while IFS= read -r image; do
  [ -n "$image" ] || continue
  # Docker reads the caller's existing DOCKER_CONFIG. The harness never copies
  # or prints registry credentials. The archive filename is sequence-based so
  # image names never become filesystem paths. The EXIT trap removes a partial
  # archive if either save or the Kind import fails.
  docker pull "$image" >/dev/null
  image_count=$((image_count + 1))
  archive="$ARCHIVE_DIR/image-$image_count.tar"
  docker image save --platform "$kind_platform" --output "$archive" "$image" >/dev/null
  if [ ! -s "$archive" ]; then
    echo "FAIL: platform-specific image archive is empty: $image" >&2
    exit 1
  fi
  kind load image-archive --name "$CLUSTER" "$archive" >/dev/null
  rm -f -- "$archive"
  archive=""
done < "$IMAGE_LIST"

echo "Kind preload: loaded $image_count rendered topology image(s) into all $node_count node(s) of $CLUSTER." >&2
