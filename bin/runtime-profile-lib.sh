#!/usr/bin/env bash
# Shared, Bash-3.2-compatible validation helpers for the non-secret S1
# runtime profile. This deliberately parses only the generated v1 grammar.

runtime_profile_regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

# S1 state is deliberately relocatable.  The profile records this symbolic
# contract rather than a source basename: the actual non-secret snapshot is
# always the deterministic sibling of the selected env.  For example,
# /srv/lucairn/customer.env is paired with
# /srv/lucairn/customer.env.image-manifest.yaml; after bundle relocation the
# same contract yields install/customer.env.image-manifest.yaml.
runtime_profile_image_manifest_snapshot_path() {
  printf '%s.image-manifest.yaml' "$1"
}

runtime_profile_image_manifest_path_contract() {
  printf '%s' 'adjacent-env-image-manifest'
}

# S1 is deliberately a small, line-oriented format.  These helpers are also
# used before a profile is written, so an init input can never produce state
# that a later reader rejects.  Names are intentionally more restrictive than
# generic YAML scalars: they are copied between customer.env, the profile, and
# model-manifest.yaml without quoting.
runtime_profile_model_name_valid() {
  local value="$1"
  [ -n "$value" ] && [ "${#value}" -le 128 ] \
    && printf '%s' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
}

runtime_profile_model_file_valid() {
  local value="$1"
  [ -n "$value" ] && [ "${#value}" -le 128 ] \
    && [ "$value" != "." ] && [ "$value" != ".." ] \
    && printf '%s' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# MODEL_PATH is operator-declared runtime configuration, not a bundle file
# lookup.  Keep historical relative values such as ../models accepted, while
# refusing absolute paths, empty components, backslashes, control characters,
# and YAML-significant punctuation.  Model *files* are validated separately
# and can never contain a path component.
runtime_profile_model_path_valid() {
  local value="$1" component old_ifs component_index=0
  [ -n "$value" ] && [ "${#value}" -le 256 ] || return 1
  case "$value" in /*|*//*|*\\*) return 1 ;; esac
  printf '%s' "$value" | grep -Eq '^[A-Za-z0-9._/-]+$' || return 1
  old_ifs="$IFS"; IFS=/
  for component in $value; do
    [ -n "$component" ] \
      && printf '%s' "$component" | grep -Eq '^[A-Za-z0-9._-]+$' \
      || { IFS="$old_ifs"; return 1; }
    case "$component" in
      ..) [ "$component_index" -eq 0 ] || { IFS="$old_ifs"; return 1; } ;;
      .) [ "$value" = "." ] || [ "$component_index" -eq 0 ] || { IFS="$old_ifs"; return 1; } ;;
    esac
    component_index=$((component_index + 1))
  done
  IFS="$old_ifs"
}

runtime_profile_image_tag_valid() {
  local value="$1"
  [ -n "$value" ] && [ "${#value}" -le 128 ] \
    && printf '%s' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# Shared DNS-only grammar for BYOK egress policy.  Do not resolve names here:
# private enterprise DNS is a supported deployment shape.  This deliberately
# rejects IP literals and every single-label name, including localhost.
runtime_profile_dns_host_valid() {
  local host="$1" label old_ifs
  [ -n "$host" ] && [ "${#host}" -le 253 ] || return 1
  case "$host" in *[[:space:]]*|*[!A-Za-z0-9.-]*|.*|*.|*..*) return 1 ;; esac
  case "$host" in *.*) ;; *) return 1 ;; esac
  case "$host" in *[!0-9.]* ) ;; *) return 1 ;; esac
  old_ifs="$IFS"; IFS=.
  for label in $host; do
    [ -n "$label" ] && [ "${#label}" -le 63 ] || { IFS="$old_ifs"; return 1; }
    case "$label" in -*|*-) IFS="$old_ifs"; return 1 ;; esac
  done
  IFS="$old_ifs"
}

runtime_profile_byok_allowlist_valid() {
  local allowlist="$1" hostname old_ifs
  [ -n "$allowlist" ] || return 1
  case "$allowlist" in *[[:space:]]*|*'/'*|*':'*|*'@'*|*'?'*|*'#'*|,*|*,) return 1 ;; esac
  old_ifs="$IFS"; IFS=,
  for hostname in $allowlist; do
    runtime_profile_dns_host_valid "$hostname" || { IFS="$old_ifs"; return 1; }
  done
  IFS="$old_ifs"
}

runtime_profile_endpoint_valid() {
  local endpoint="$1" rest hostport host port path label remaining pair old_ifs
  case "$endpoint" in https://*) rest="${endpoint#https://}" ;; *) return 1 ;; esac
  case "$endpoint" in *[[:space:]]*|*'@'*|*'?'*|*'#'*) return 1 ;; esac
  case "$rest" in */*) hostport="${rest%%/*}"; path="/${rest#*/}" ;; *) hostport="$rest"; path="" ;; esac
  [ -n "$hostport" ] || return 1
  case "$hostport" in *:*:*) return 1 ;; *:*) host="${hostport%%:*}"; port="${hostport#*:}"; [ -n "$port" ] || return 1 ;; *) host="$hostport"; port="" ;; esac
  [ -n "$host" ] && [ "${#host}" -le 253 ] || return 1
  case "$host" in *[!A-Za-z0-9.-]*|.*|*.|*..*) return 1 ;; esac
  case "$host" in *.*) ;; *) return 1 ;; esac
  # A decimal dotted literal is never an enterprise DNS endpoint.  Do not do
  # DNS here: a valid FQDN may intentionally resolve to private infrastructure.
  case "$host" in *[!0-9.]* ) ;; *) return 1 ;; esac
  old_ifs="$IFS"; IFS=.
  for label in $host; do
    [ -n "$label" ] && [ "${#label}" -le 63 ] || { IFS="$old_ifs"; return 1; }
    case "$label" in -*|*-) IFS="$old_ifs"; return 1 ;; esac
  done
  IFS="$old_ifs"
  if [ -n "$port" ]; then
    printf '%s' "$port" | grep -Eq '^[0-9]+$' || return 1
    awk -v p="$port" 'BEGIN { exit !(p >= 1 && p <= 65535) }' || return 1
  fi
  case "$path" in "") return 0 ;; /*) ;; *) return 1 ;; esac
  printf '%s' "$path" | grep -Eq "^/[-A-Za-z0-9._~!\$&'()*+,;=:%/]*$" || return 1
  remaining="$path"
  while case "$remaining" in *%*) true ;; *) false ;; esac; do
    remaining="${remaining#*%}"; [ "${#remaining}" -ge 2 ] || return 1
    pair="${remaining:0:2}"
    printf '%s' "$pair" | grep -Eq '^[0-9A-Fa-f][0-9A-Fa-f]$' || return 1
    remaining="${remaining:2}"
  done
}

# Reject all YAML constructs except the exact, unquoted scalar/list/map shape
# emitted by lucairn-init.  This must run before any field accessor or copy.
runtime_profile_validate_syntax() {
  local profile="$1"
  runtime_profile_regular_file "$profile" || return 1
  awk '
    function value(line, prefix, v) {
      if (index(line, prefix) != 1) return ""
      v=substr(line, length(prefix)+1)
      return scalar(v) ? v : ""
    }
    function scalar(v) { return v ~ /^[^[:space:]#][^[:space:]]*$/ && v !~ /[&*!|>{}\[\]#]/ }
    function want(prefix) { if ((v=value($0,prefix)) == "") bad=1; return v }
    BEGIN { state=0; records=0; mode="" }
    {
      if (NR == 1 && $0 == "# Lucairn runtime profile -- generated by bin/lucairn-init. Contains no secrets.") next
      if ($0 == "" || $0 ~ /\r/ || $0 ~ /^[[:space:]]*#/) { bad=1; next }
      if (state == 0) { if (want("schema_version: ") != "1") bad=1; state=1; next }
      if (state == 1) { mode=want("runtime_mode: "); state=2; next }
      if (state == 2) { want("deployment_profile: "); state=3; next }
      if (state == 3) { want("local_runtime: "); state=4; next }
      if (state == 4) { want("remote_endpoint: "); state=5; next }
      if (state == 5) { want("byok_egress_allowlist: "); state=6; next }
      if (state == 6) { want("image_tag: "); state=7; next }
      if (state == 7) { if ($0 != "overlays:") bad=1; state=8; next }
      if (state == 8) {
        if ($0 ~ /^  - [^[:space:]#][^[:space:]]*$/) { overlays++; next }
        if ($0 == "image_manifest:") { if (!overlays) bad=1; state=9; next }
        bad=1; next
      }
      if (state == 9) { want("  path: "); state=10; next }
      if (state == 10) { want("  sha256: "); state=11; next }
      if (state == 11) { want("  registry: "); state=12; next }
      if (state == 12) { if ($0 != "  recorded_images:") bad=1; state=13; next }
      if (state == 13) {
        if ($0 ~ /^    - ref: [^[:space:]#][^[:space:]]*$/) { records++; state=14; next }
        bad=1; next
      }
      if (state == 14) {
        if ($0 !~ /^      digest: [^[:space:]#][^[:space:]]*$/) bad=1
        state=15; next
      }
      if (state == 15) {
        if ($0 ~ /^    - ref: [^[:space:]#][^[:space:]]*$/) { records++; state=14; next }
        if ($0 == "model_inventory:") { if (!records) bad=1; state=(mode == "local-runtime" ? 16 : 22); next }
        bad=1; next
      }
      if (state == 16) { want("  provenance: "); state=17; next }
      if (state == 17) { want("  availability: "); state=18; next }
      if (state == 18) { want("  model_name: "); state=19; next }
      if (state == 19) { want("  model_file: "); state=20; next }
      if (state == 20) { want("  model_path: "); state=21; next }
      if (state == 21) { want("  runtime: "); state=99; next }
      if (state == 22) { want("  provenance: "); state=23; next }
      if (state == 23) { want("  local_model: "); state=99; next }
      bad=1
    }
    END { exit (bad || state != 99) }
  ' "$profile"
}

# Syntax says the profile is unambiguous YAML in the generated shape.  This
# semantic pass says its scalar vocabulary is safe to reproduce in every S1
# artifact.  It deliberately has no customer.env dependency, allowing init to
# apply it to private staged files before publication.
runtime_profile_validate_semantics() {
  local profile="$1" mode deployment local_runtime remote_endpoint allowlist image_tag
  runtime_profile_validate_syntax "$profile" || return 1
  mode="$(runtime_profile_field "$profile" runtime_mode)" || return 1
  deployment="$(runtime_profile_field "$profile" deployment_profile)" || return 1
  local_runtime="$(runtime_profile_field "$profile" local_runtime)" || return 1
  remote_endpoint="$(runtime_profile_field "$profile" remote_endpoint)" || return 1
  allowlist="$(runtime_profile_field "$profile" byok_egress_allowlist)" || return 1
  image_tag="$(runtime_profile_field "$profile" image_tag)" || return 1
  [ "$deployment" = "$mode" ] || return 1
  runtime_profile_image_tag_valid "$image_tag" || return 1
  case "$mode" in
    split-remote)
      [ "$local_runtime" = "none" ] && [ "$allowlist" = "none" ] \
        && runtime_profile_endpoint_valid "$remote_endpoint" || return 1
      ;;
    managed-byok)
      [ "$local_runtime" = "none" ] && [ "$remote_endpoint" = "none" ] \
        && runtime_profile_byok_allowlist_valid "$allowlist" || return 1
      ;;
    local-runtime)
      case "$local_runtime" in llama-cpp|vllm|tgi|ollama|onnxruntime|triton|custom-runtime) ;; *) return 1 ;; esac
      [ "$remote_endpoint" = "none" ] && [ "$allowlist" = "none" ] || return 1
      runtime_profile_model_name_valid "$(runtime_profile_field "$profile" model_name)" || return 1
      runtime_profile_model_file_valid "$(runtime_profile_field "$profile" model_file)" || return 1
      runtime_profile_model_path_valid "$(runtime_profile_field "$profile" model_path)" || return 1
      [ "$(runtime_profile_field "$profile" runtime)" = "$local_runtime" ] || return 1
      ;;
    *) return 1 ;;
  esac
}

runtime_profile_field() {
  local profile="$1" key="$2" count value
  runtime_profile_validate_syntax "$profile" || return 1
  count="$(grep -c "^[[:space:]]*${key}:" "$profile" 2>/dev/null || true)"
  [ "$count" = "1" ] || return 1
  value="$(sed -n "s/^[[:space:]]*${key}: //p" "$profile")"
  [ -n "$value" ] && printf '%s' "$value"
}

runtime_profile_field_absent() {
  local profile="$1" key="$2"
  runtime_profile_validate_syntax "$profile" || return 1
  ! grep -q "^[[:space:]]*${key}:" "$profile"
}

runtime_profile_overlays() {
  runtime_profile_validate_syntax "$1" || return 1
  sed -n '/^overlays:/,/^image_manifest:/ { s/^  - //p; }' "$1"
}

runtime_profile_image_manifest_value() {
  local profile="$1" key="$2"
  runtime_profile_validate_syntax "$profile" || return 1
  sed -n "s/^  ${key}: //p" "$profile"
}

runtime_profile_recorded_images() {
  runtime_profile_validate_syntax "$1" || return 1
  awk '/^    - ref: / { ref=$0; sub(/^    - ref: /,"",ref); next }
       /^      digest: / { digest=$0; sub(/^      digest: /,"",digest); print ref "|" digest }' "$1"
}

runtime_profile_manifest_images() {
  local manifest="$1"
  runtime_profile_regular_file "$manifest" || return 1
  awk '
    /^[[:space:]]*ref:[[:space:]]*/ {
      ref=$0; sub(/^[[:space:]]*ref:[[:space:]]*/, "", ref); gsub(/^"|"$/, "", ref)
    }
    /^[[:space:]]*digest:[[:space:]]*/ && ref != "" {
      digest=$0; sub(/^[[:space:]]*digest:[[:space:]]*/, "", digest); gsub(/^"|"$/, "", digest)
      print ref "|" digest; ref=""
    }
  ' "$manifest"
}

runtime_profile_images_valid() {
  local pairs="$1" refs
  [ -n "$pairs" ] || return 1
  while IFS='|' read -r ref digest; do
    printf '%s' "$ref" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$' || return 1
    printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' || return 1
  done <<EOF
$pairs
EOF
  refs="$(printf '%s\n' "$pairs" | cut -d'|' -f1)"
  [ "$(printf '%s\n' "$refs" | sort | uniq -d | wc -l | tr -d ' ')" = "0" ]
}

runtime_profile_env_value() {
  local env="$1" key="$2" count value
  count="$(grep -c "^${key}=" "$env" 2>/dev/null || true)"
  [ "$count" -le 1 ] || return 1
  [ "$count" = "1" ] || { printf ''; return 0; }
  value="$(sed -n "s/^${key}=//p" "$env")"; printf '%s' "$value"
}

runtime_profile_env_value_required() {
  local env="$1" key="$2" count value
  count="$(grep -c "^${key}=" "$env" 2>/dev/null || true)"
  [ "$count" = "1" ] || return 1
  value="$(sed -n "s/^${key}=//p" "$env")"; printf '%s' "$value"
}
