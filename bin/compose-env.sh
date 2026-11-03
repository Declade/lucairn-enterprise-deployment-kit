# shellcheck shell=bash
# compose-env.sh — customer.env values exactly as Docker Compose hands them on.
#
# Kit 2.0 K-A fix round 2 (sol r2 on PR #158, findings e + f). Sourced by
# scripts/write-sanitizer-core-registry-dsn.sh, bin/lucairn-init and
# bin/lucairn (doctor, support-bundle). It REPLACES the hand-written env-file
# reader (bin/compose-env-lib.sh, removed): nothing here parses customer.env.
# Every value comes from Docker Compose ITSELF, so quotes, multi-line values,
# backslash escapes ("\0101" is "A" to Compose), $-interpolation, a line feed
# inside quotes and a variable exported in the shell are resolved by Compose
# and cannot be read differently here.
#
# How (each run is `docker compose ... config --format json`, client side
# only: no daemon, no container):
#   file view    a throw-away project whose one service has
#                `env_file: <customer.env>`: Compose's own env-file parser
#                gives every key and value of the file (exported shell
#                variables do NOT change these: Compose's env_file rule).
#   interpolation view
#                a throw-away project whose service maps every key K of the
#                file to "${K-}": what Compose interpolates `${K}` to from THIS
#                shell — an exported variable wins over the file, exactly as
#                `docker compose up` run here sees it.
#   project      the install's own project (its -f files), for the values
#                Compose hands every container, and to cross-check that the
#                registry DB gets the interpolated password and the core
#                mounts the DSN file that was checked.
#
# Reading Compose's output is the only parsing done here: JSON as Compose
# prints it (Go encoding/json, two-space indent, one member per line), whose
# strings are decoded by RFC 8259 §7 (the awk below), after which Compose's
# own `$` -> `$$` escape of `config` output is undone. Output that is not in
# that shape is refused, never guessed. No Python: offline doctor stays
# usable on hosts without it (INSTALL.md § Requirements).
#
# Functions (bash 3.2; stdout = `name<TAB>value` fields that never hold a
# value, except `dsn` of `--print-dsn` and the needle list):
#   cev_registry --env-file F --project-dir D [--dsn-file P] [--check-file]
#                [--print-dsn] [-- <compose args: -f ... --profile ...>]
#   cev_needles  --env-file F --project-dir D -- <compose args>
#   cev_to_json  yaml|env <file> <out.json>   (support-bundle's decoded scan)
# rc: 0 done · 10 Docker Compose is not available (fail closed) · 11 Compose
# refuses customer.env · 12 Compose output this file cannot use · 2 usage.
# On rc != 0 a value-free reason is on stderr, as `compose-env: <reason>`.
# Both run in a subshell: their private temp directory (the rendered JSON
# holds secrets; mode 0700) is always removed.

CEV_DSN_TARGET="/run/secrets/sanitizer-core/registry-dsn"
CEV_DEFAULT_DSN_FILE="./.secrets/sanitizer-core/registry-dsn"

# The JSON reader. Modes (awk -v mode=...):
#   keys      file 1 = file view: the env names Compose can interpolate
#   registry  files: file view, interpolation view, [project]; -v dsnfile,
#             -v projdir, -v given, -v checkfile, -v printdsn
#   needles   files: file view, interpolation view, [project]; then the
#             DSN files named by -v dsnfiles (newline-separated)
# shellcheck disable=SC2016 # an awk program: its $ are awk fields, not shell
CEV_AWK='
function jtok(s, i,    j, c) {          # index of the closing quote of the string at s[i]
  for (j = i + 1; j <= length(s); j++) {
    c = substr(s, j, 1)
    if (c == "\\") { j++; continue }
    if (c == "\"") return j
  }
  return 0
}
function hexv(h,    i, c, v) {
  if (length(h) != 4) return -1
  v = 0
  for (i = 1; i <= 4; i++) {
    c = index("0123456789abcdef", tolower(substr(h, i, 1)))
    if (!c) return -1
    v = v * 16 + c - 1
  }
  return v
}
function utf8(cp) {
  if (cp < 128) return sprintf("%c", cp)
  if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
  if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
  return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
}
# RFC 8259 string body -> bytes; then Compose `$$` -> `$`. BAD on anything
# else (an unknown escape, a NUL, a lone `$`).
function jdec(t,    out, i, n, c, e, cp, lo, parts, k, m) {
  out = ""; n = length(t)
  for (i = 1; i <= n; i++) {
    c = substr(t, i, 1)
    if (c != "\\") { out = out c; continue }
    e = substr(t, ++i, 1)
    if (e == "\"" || e == "\\" || e == "/") out = out e
    else if (e == "n") out = out "\n"
    else if (e == "t") out = out "\t"
    else if (e == "r") out = out "\r"
    else if (e == "b") out = out "\b"
    else if (e == "f") out = out "\f"
    else if (e == "u") {
      cp = hexv(substr(t, i + 1, 4)); i += 4
      if (cp <= 0) return BAD
      if (cp >= 55296 && cp < 56320) {
        lo = (substr(t, i + 1, 2) == "\\u") ? hexv(substr(t, i + 3, 4)) : -1
        if (lo < 56320 || lo >= 57344) return BAD
        cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); i += 6
      } else if (cp >= 56320 && cp < 57344) return BAD
      out = out utf8(cp)
    } else return BAD
  }
  m = split(out, parts, "\\$\\$")
  for (k = 1; k <= m; k++) if (index(parts[k], "$")) return BAD
  out = parts[1]
  for (k = 2; k <= m; k++) out = out "$" parts[k]
  return out
}
function push(k) { sp++; stk[sp] = k }
function pop() { if (sp > 0) sp-- }
function path(    i, p) { p = ""; for (i = 1; i <= sp; i++) p = p (i > 1 ? "/" : "") stk[i]; return p }
# One line of indented JSON -> scalar(path, key, token, isstring).
function line(l,    j, key, rest, tok) {
  sub(/^[ \t]+/, "", l)
  if (l ~ /^[\]}],?$/) { pop(); return }
  if (l == "{" || l == "[") { if (top++) push("#" (++elem)); return }
  if (substr(l, 1, 1) != "\"") return
  j = jtok(l, 1)
  if (!j) { broken = 1; return }
  key = substr(l, 2, j - 2); rest = substr(l, j + 1)
  if (rest == "" || rest == ",") { scalar(path(), "#", key, 1); return }
  if (substr(rest, 1, 2) != ": ") { broken = 1; return }
  rest = substr(rest, 3)
  if (rest == "{" || rest == "[") { push(key); return }
  if (substr(rest, 1, 1) == "\"") {
    j = jtok(rest, 1)
    if (!j) { broken = 1; return }
    scalar(path(), key, substr(rest, 2, j - 2), 1)
  } else if (rest ~ /^null,?$/) scalar(path(), key, "", 0)
}
function secretname(k,    u) {
  u = toupper(k)
  if (u == "MIGRATE_CEILING_KEY") return 0      # the migrate runners name a ceiling, not a secret
  if (u ~ /PUBLIC|PUBKEY/ || u ~ /(_ID|_NAME|_PATH|_FILE|_DIR|_DAYS|_URL)$/) return 0
  return u ~ /PASSWORD|SECRET|TOKEN|KEY|DSN|PRIVATE|CREDENTIAL|LICENSE/
}
function pct(s,    i, c, o) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c ~ /[A-Za-z0-9._~-]/) o = o c
    else o = o sprintf("%%%02X", ord[c])
  }
  return o
}
function pctdec(s,    o, i, c, h) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    h = (c == "%") ? substr(s, i + 1, 2) : ""
    if (h ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) { o = o sprintf("%c", hexv("00" h)); i += 2 } else o = o c
  }
  return o
}
function userinfo(v,    s, m, pw) {   # every scheme://user:password@ password in v
  s = v
  while (match(s, /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^:\/@ \t\n]*:[^@ \t\n]*@/)) {
    m = substr(s, RSTART, RLENGTH)
    sub(/^[^:]*:\/\/[^:]*:/, "", m); sub(/@$/, "", m)
    if (m != "") { addval(m); addval(pctdec(m)) }
    s = substr(s, RSTART + RLENGTH)
  }
}
function normpath(p,    a, n, i, out, o, k) {
  if (substr(p, 1, 1) != "/") p = projdir "/" p
  n = split(p, a, "/"); o = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "" || a[i] == ".") continue
    if (a[i] == "..") { if (o > 0) o--; continue }
    out[++o] = a[i]
  }
  p = ""
  for (k = 1; k <= o; k++) p = p "/" out[k]
  return p == "" ? "/" : p
}
function pwstate(v,    i, c) {
  if (v == BAD) return "unsafe"
  if (v == "") return "unset"
  if (v ~ /^REPLACE_ME_/ || v ~ /^REPLACE_WITH_/) return "placeholder"
  for (i = 1; i <= length(v); i++) {
    c = substr(v, i, 1)
    if (ord[c] < 33 || ord[c] > 126 || index("$\047\"\\`#", c)) return "unsafe"
  }
  return "ok"
}
function addval(v) { if (v != "" && v != BAD) vals[++nv] = v }
function readfile(f,    l, s, n) {      # the DSN file as the core reads it (BOM, TrimSpace)
  s = ""; n = 0
  while ((getline l < f) > 0) { s = s (n++ ? "\n" : "") l }
  close(f)
  if (substr(s, 1, 3) == "\357\273\277") s = substr(s, 4)
  sub(/^[ \t\r\n\v\f]+/, "", s); sub(/[ \t\r\n\v\f]+$/, "", s)
  return s
}
function scalar(p, k, tok, isstr,    v, svc) {
  if (fno == 1 || fno == 2) {
    if (p != "services/probe/environment") return
    if (mode == "keys") { if (k ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print k; return }
    if (fno == 1) { A[k] = tok; Aset[k] = 1 } else { B[k] = tok; Bset[k] = 1 }
    if (mode == "needles" && isstr) { v = jdec(tok); userinfo(v); if (secretname(k)) addval(v) }
    return
  }
  # fno == 3: the project
  if (p ~ /^services\/[^\/]+\/environment$/) {
    svc = p; sub(/^services\//, "", svc); sub(/\/environment$/, "", svc)
    if (mode == "registry") {
      if (svc == "postgres-sanitizer-core" && k == "POSTGRES_PASSWORD") { pdb = tok; pdbset = 1 }
      if (svc == "migrate-sanitizer-core" && k == "PGPASSWORD") { pmig = tok; pmigset = 1 }
      if (svc == "migrate-sanitizer-core" && k == "PGSSLMODE") { pssl = tok; psslset = 1 }
      return
    }
    if (isstr) { v = jdec(tok); userinfo(v); if (secretname(k)) addval(v) }
    return
  }
  if (p ~ /^services\/sanitizer-core\/volumes\/#[0-9]+$/ && (k == "source" || k == "target")) {
    vol[p, k] = tok; vols[p] = 1
  }
  if (mode == "needles" && isstr) userinfo(jdec(tok))
}
BEGIN {
  readable = ENVIRON["CEV_READABLE"]
  BAD = "\001BAD"
  for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i
}
FNR == 1 { fno++; sp = 0; elem = 0; top = 0 }
/^  "services": [{]$/ { seen[fno] = 1 }
{ line($0) }
END {
  if (broken || !seen[1] || (fno >= 2 && !seen[2])) { print "unreadable"; exit 12 }
  if (needproj && !seen[3]) { print "unreadable"; exit 12 }   # needles: the project MUST have been read
  if (mode == "keys") exit 0
  if (mode == "registry") {
    split("POSTGRES_SANITIZER_CORE_PASSWORD POSTGRES_SSLMODE SANITIZER_CORE_REGISTRY_DSN_FILE", R, " ")
    ov = ""
    for (i = 1; i <= 3; i++) if ((Aset[R[i]] ? A[R[i]] : "") != (Bset[R[i]] ? B[R[i]] : "")) ov = ov (ov == "" ? "" : ",") R[i]
    print "compose\tok"
    print "overrides\t" ov
    pw = jdec(B["POSTGRES_SANITIZER_CORE_PASSWORD"]); st = pwstate(pw)
    print "pw\t" st
    print "pw_len\t" (pw == BAD ? 0 : length(pw))
    ssl = jdec(B["POSTGRES_SSLMODE"]); if (ssl == "") ssl = "disable"
    sslok = (ssl ~ /^(disable|allow|prefer|require|verify-ca|verify-full)$/)
    print "sslmode\t" (sslok ? ssl : "invalid")
    f = given
    if (f == "") { f = jdec(B["SANITIZER_CORE_REGISTRY_DSN_FILE"]); if (f == BAD) { print "dsn_file_state\tunusable"; exit 0 } }
    if (f == "") f = dflt
    f = normpath(f)
    for (i = 1; i <= length(f); i++) if (ord[substr(f, i, 1)] < 32 || ord[substr(f, i, 1)] == 127) { print "dsn_file_state\tunusable"; exit 0 }
    print "dsn_file\t" f
    expected = ""
    if (st == "ok" && sslok) expected = "postgres://dsa:" pct(pw) "@postgres-sanitizer-core:5432/sanitizer_core?sslmode=" ssl
    if (checkfile != "") {
      if (checkfile == "read") {
        d = readfile(f)
        if (d == "") fs = "empty"
        else if (d !~ /^postgres(ql)?:\/\//) fs = "not-url"
        else if (expected == "") fs = "unchecked"
        else fs = (d == expected) ? "match" : "mismatch"
      } else fs = checkfile
      print "file\t" fs
    }
    if (fno >= 3) {
      if (!seen[3]) print "project\tnot-rendered"
      else {
        print "project\trendered"
        print "project_db_password\t" (!pdbset ? "absent" : (jdec(pdb) == pw ? "same" : "differs"))
        print "project_migrate_password\t" (!pmigset ? "absent" : (jdec(pmig) == pw ? "same" : "differs"))
        print "project_migrate_sslmode\t" (!psslset ? "absent" : (jdec(pssl) == ssl ? "same" : "differs"))
        mnt = "absent"
        for (v in vols) if (jdec(vol[v, "target"]) == target) mnt = (normpath(jdec(vol[v, "source"])) == f ? "same" : "differs")
        print "project_dsn_mount\t" mnt
      }
    }
    if (printdsn != "" && expected != "") print "dsn\t" expected
    exit 0
  }
  if (mode == "dsnpaths") {               # the interpolated DSN path + every rendered mount
    f = jdec(B["SANITIZER_CORE_REGISTRY_DSN_FILE"]); if (f == "" || f == BAD) f = dflt
    print normpath(f)
    for (v in vols) if (jdec(vol[v, "target"]) == target) print normpath(jdec(vol[v, "source"]))
    exit 0
  }
  # needles
  for (v in vols) if (jdec(vol[v, "target"]) == target) dsnf[normpath(jdec(vol[v, "source"]))] = 1
  f = jdec(B["SANITIZER_CORE_REGISTRY_DSN_FILE"]); if (f == "" || f == BAD) f = dflt
  dsnf[normpath(f)] = 1
  for (f in dsnf) if (index(readable, "\n" f "\n")) { d = readfile(f); if (d != "") { addval(d); userinfo(d) } }
  # The DECODED values only (K-A fix round 4, sol r3): no escaped or encoded
  # variant is generated here any more. support-bundle parses every collected
  # file with the parser of its format and compares decoded strings against
  # these (bin/lucairn support_bundle_decoded_scan); the raw substring scan
  # of the same list stays as a second layer.
  for (i = 1; i <= nv; i++) {
    v = vals[i]
    if (v ~ /^(\/|\.\/|\.\.\/|~\/)/) continue
    frag(v)
  }
}
function frag(s,    n, a, i) {
  n = split(s, a, "\n")
  for (i = 1; i <= n; i++) if (length(a[i]) >= 12) print a[i]
}
'

cev_fail() { printf 'compose-env: %s\n' "$2" >&2; return "$1"; }

# Sets CEV_CMD (the Compose command words) or fails with rc 10.
cev_compose_cmd() {
  CEV_CMD=()
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 </dev/null; then
    CEV_CMD=(docker compose); return 0
  fi
  if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1 </dev/null; then
    CEV_CMD=(docker-compose); return 0
  fi
  cev_fail 10 "Docker Compose is not available here (neither \`docker compose\` nor \`docker-compose\` is on PATH). customer.env is read through Compose itself and never guessed: run this on the Docker host, or install the Compose plugin"
}

# A value-free reason for a refused render (Compose's own message can quote
# customer.env, so only a `required variable X` name is passed on).
cev_reason() {
  local v
  v="$(LC_ALL=C sed -n 's/.*required variable \([A-Za-z_][A-Za-z0-9_]*\) is missing a value.*/\1/p' "$1" | head -1)"
  if [ -n "$v" ]; then printf 'required variable %s is missing a value' "$v"
  else printf "Docker Compose refused it; its message is not printed because it can quote customer.env (run the same \`docker compose ... config --quiet\` yourself to read it)"; fi
}

# cev_render <out> <env file> <project dir|""> <compose args...>; rc 0 / 11.
cev_render() {
  local out="$1" env="$2" pd="$3"
  shift 3
  local -a pdargs=()
  [ -z "$pd" ] || pdargs=(--project-directory "$pd")
  if "${CEV_CMD[@]}" ${pdargs[@]+"${pdargs[@]}"} "$@" --env-file "$env" config --format json \
       > "$out" 2> "$CEV_TMP/err" </dev/null; then
    return 0
  fi
  CEV_REASON="$(cev_reason "$CEV_TMP/err")"
  : > "$out"
  return 11
}

# JSON string body for a path (the env file's own path goes into a probe file).
cev_jstr() {
  local s="$1"
  case "$s" in *[[:cntrl:]]*) return 1 ;; esac
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# The file view + interpolation view probes into $CEV_TMP/a.json, b.json.
# $3 = "all" (every interpolable key of the file) or "registry".
cev_probes() {
  local env="$1" pd="$2" which="$3" abs ej k keys first seenk=""
  case "$env" in /*) abs="$env" ;; *) abs="$PWD/$env" ;; esac
  ej="$(cev_jstr "$abs")" || { cev_fail 11 "the env file path holds a control character"; return; }
  printf '{"name":"lucairn-env-probe","services":{"probe":{"image":"lucairn-env-probe","env_file":[{"path":"%s","required":true}]}}}\n' "$ej" > "$CEV_TMP/probe-a.json"
  if ! cev_render "$CEV_TMP/a.json" "$env" "$pd" -f "$CEV_TMP/probe-a.json"; then
    cev_fail 11 "Docker Compose cannot read $env: $CEV_REASON"; return
  fi
  keys="POSTGRES_SANITIZER_CORE_PASSWORD POSTGRES_SSLMODE SANITIZER_CORE_REGISTRY_DSN_FILE"
  if [ "$which" = all ]; then
    keys="$keys $(LC_ALL=C awk -v mode=keys "$CEV_AWK" "$CEV_TMP/a.json" | tr '\n' ' ')" \
      || { cev_fail 12 "\`docker compose config --format json\` gave output this kit cannot read (Docker Compose v2 is required)"; return; }
  fi
  {
    printf '{"name":"lucairn-env-probe","services":{"probe":{"image":"lucairn-env-probe","environment":{'
    first=1
    for k in $keys; do
      case " $seenk " in *" $k "*) continue ;; esac
      seenk="${seenk:-} $k"
      [ "$first" -eq 1 ] || printf ','
      first=0
      # shellcheck disable=SC2016 # "${K-}" is for Compose to interpolate
      printf '"%s":"${%s-}"' "$k" "$k"
    done
    printf '}}}}\n'
  } > "$CEV_TMP/probe-b.json"
  if ! cev_render "$CEV_TMP/b.json" "$env" "$pd" -f "$CEV_TMP/probe-b.json"; then
    cev_fail 11 "Docker Compose cannot read $env: $CEV_REASON"; return
  fi
}

cev_args() { # parses the common options into CEV_OPT_*; sets CEV_ARGS (compose args)
  CEV_OPT_ENV="" CEV_OPT_PD="" CEV_OPT_DSN="" CEV_OPT_CHECK="" CEV_OPT_PRINT=""
  CEV_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env-file) CEV_OPT_ENV="$2"; shift 2 ;;
      --project-dir) CEV_OPT_PD="$2"; shift 2 ;;
      --dsn-file) CEV_OPT_DSN="$2"; shift 2 ;;
      --check-file) CEV_OPT_CHECK=1; shift ;;
      --print-dsn) CEV_OPT_PRINT=1; shift ;;
      --) shift; CEV_ARGS=("$@"); break ;;
      *) cev_fail 2 "unknown argument: $1"; return ;;
    esac
  done
  [ -n "$CEV_OPT_ENV" ] && [ -n "$CEV_OPT_PD" ] || { cev_fail 2 "--env-file and --project-dir are required"; return; }
  [ -f "$CEV_OPT_ENV" ] || { cev_fail 11 "$CEV_OPT_ENV is not a regular file"; return; }
  CEV_OPT_PD="$(cd "$CEV_OPT_PD" 2>/dev/null && pwd)" || { cev_fail 2 "project directory not found"; return; }
}

cev_tmp() {
  CEV_TMP="$(mktemp -d "${TMPDIR:-/tmp}/lucairn-env-probe.XXXXXX")" || { cev_fail 12 "cannot create a private temp directory"; return; }
  chmod 0700 "$CEV_TMP"
}

# cev_registry ... — see the header. Runs in a subshell so its temp directory
# (rendered JSON holds secrets, mode 0700) is always removed.
cev_registry() (
  cev_args "$@" || exit
  cev_compose_cmd || exit
  cev_tmp || exit
  trap 'rm -rf "$CEV_TMP"' EXIT
  cev_probes "$CEV_OPT_ENV" "$CEV_OPT_PD" registry || exit
  local files=("$CEV_TMP/a.json" "$CEV_TMP/b.json") check="" f st
  if [ "${#CEV_ARGS[@]}" -gt 0 ]; then
    cev_render "$CEV_TMP/p.json" "$CEV_OPT_ENV" "" "${CEV_ARGS[@]}" --profile sanitizer-core-migrate || true
    files+=("$CEV_TMP/p.json")
  fi
  if [ -n "$CEV_OPT_CHECK" ]; then
    # The file's path first (same reader, no check), then its state.
    f="$(LC_ALL=C awk -v mode=registry -v projdir="$CEV_OPT_PD" -v given="$CEV_OPT_DSN" -v dflt="$CEV_DEFAULT_DSN_FILE" \
         "$CEV_AWK" "$CEV_TMP/a.json" "$CEV_TMP/b.json" | sed -n 's/^dsn_file	//p')"
    if [ -z "$f" ]; then check=""
    elif [ -L "$f" ]; then check=symlink
    elif [ -d "$f" ]; then check=directory
    elif [ ! -e "$f" ]; then check=missing
    elif [ ! -f "$f" ]; then check=not-regular
    elif [ ! -r "$f" ]; then check=unreadable
    elif [ "$(wc -c < "$f" | tr -d ' ')" -gt 8192 ]; then check=too-big
    else check="read"; fi
  fi
  LC_ALL=C awk -v mode=registry -v projdir="$CEV_OPT_PD" -v given="$CEV_OPT_DSN" -v dflt="$CEV_DEFAULT_DSN_FILE" \
    -v checkfile="$check" -v printdsn="$CEV_OPT_PRINT" -v target="$CEV_DSN_TARGET" \
    "$CEV_AWK" "${files[@]}"
  st=$?
  [ "$st" -eq 0 ] || cev_fail 12 "\`docker compose config --format json\` gave output this kit cannot read (Docker Compose v2 is required)"
)

# cev_needles ... — every secret value Compose knows for this install, DECODED
# (see bin/lucairn support_bundle_secret_needles). The install's project (its
# compose args after `--`) is REQUIRED and must render: a project Compose
# refuses, or whose output is not a project, fails the call (rc 11 / 12) —
# the secret list is never built from the env probes alone (K-A fix round 4,
# sol r3: an unrelated missing variable used to drop every secret only the
# compose files carry, and the bundle went on).
cev_needles() (
  cev_args "$@" || exit
  [ "${#CEV_ARGS[@]}" -gt 0 ] || { cev_fail 2 "the install's compose files (after --) are required"; exit; }
  cev_compose_cmd || exit
  cev_tmp || exit
  trap 'rm -rf "$CEV_TMP"' EXIT
  cev_probes "$CEV_OPT_ENV" "$CEV_OPT_PD" all || exit
  local files=("$CEV_TMP/a.json" "$CEV_TMP/b.json" "$CEV_TMP/p.json") readable="" f
  if ! cev_render "$CEV_TMP/p.json" "$CEV_OPT_ENV" "" "${CEV_ARGS[@]}"; then
    cev_fail 11 "Docker Compose cannot render this install's project: $CEV_REASON"; exit
  fi
  # The DSN files (the interpolated path and every rendered mount): readable
  # regular files of at most 8 KiB only.
  local cands
  cands="$(LC_ALL=C awk -v mode=dsnpaths -v projdir="$CEV_OPT_PD" -v dflt="$CEV_DEFAULT_DSN_FILE" \
             -v target="$CEV_DSN_TARGET" "$CEV_AWK" "${files[@]}")" || true
  readable="
"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] && [ "$(wc -c < "$f" | tr -d ' ')" -le 8192 ]; then
      readable="$readable$f
"
    fi
  done < <(printf '%s\n' "$cands")
  CEV_READABLE="$readable" LC_ALL=C awk -v mode=needles -v needproj=1 -v projdir="$CEV_OPT_PD" -v dflt="$CEV_DEFAULT_DSN_FILE" \
    -v target="$CEV_DSN_TARGET" "$CEV_AWK" "${files[@]}" > "$CEV_TMP/needles"
  st=$?
  [ "$st" -eq 0 ] || { cev_fail 12 "\`docker compose config --format json\` gave output this kit cannot read (Docker Compose v2 is required), or the install's project rendered no services"; exit; }
  LC_ALL=C sort -u "$CEV_TMP/needles"
)

# cev_to_json <yaml|env> <in> <out> — one support-bundle file, decoded by
# Docker Compose's OWN parsers into JSON at <out> (K-A fix round 4, sol r3:
# the decoded comparison of bin/lucairn support_bundle_decoded_scan; no
# hand-written YAML or env-file reader here or there):
#   yaml  the file's lines, each indented two spaces under ONE top-level
#         `x-lucairn-bundle-scan:` key. Compose passes `x-` extension content
#         through unvalidated, so its YAML parser (go-yaml) decodes ANY
#         document — quoting, '' and "\x41" escapes, folding, anchors —
#         and nothing in it is interpreted as a project (no include, no
#         extends, no path or env resolution). Rendered --no-interpolate: a
#         `$` stays as written (`$$` stays `$$`; the scanner compares the
#         `$$`-undone forms too). A document marker (---, ...) or directive
#         (%) on its own line cannot sit under one key: refused (rc 11), as is
#         anything Compose's parser refuses. redact_stream's whole-line
#         marker for a line over 8 KiB carries no data and becomes a comment.
#   env   a probe service with `env_file: <in>`: Compose's dotenv parser
#         (quotes, escapes, `export`, comments, multi-line values). Every `$`
#         of the file is doubled first, so nothing is interpolated from this
#         shell or the file: the result is the file's own text, decoded
#         (a `$` inside single quotes comes back doubled; the scanner's `$$`-
#         undone forms cover it).
# rc: 0 · 10 no Docker Compose · 11 Compose refused the file · 2 usage.
# Runs in a subshell; its private temp directory (mode 0700) is removed.
cev_to_json() (
  local kind="$1" in="$2" out="$3" ej
  [ -f "$in" ] && [ ! -L "$in" ] || { cev_fail 2 "not a regular file"; exit; }
  cev_compose_cmd || exit
  cev_tmp || exit
  trap 'rm -rf "$CEV_TMP"' EXIT
  local -a args=()
  case "$kind" in
    yaml)
      LC_ALL=C awk '
        NR == 1 { print "x-lucairn-bundle-scan:"; sub(/^\357\273\277/, "") }
        /^(---|\.\.\.)([ \t\r]|$)/ || /^%/ { bad = 1; exit }
        $0 == "<redacted: line exceeds 8192 bytes>" { print "  #"; next }
        { print "  " $0 }
        END { if (NR == 0) print "x-lucairn-bundle-scan:"; exit bad }
      ' "$in" > "$CEV_TMP/wrapped.yml" \
        || { cev_fail 11 "it holds a YAML document marker or directive line"; exit; }
      args=(-f "$CEV_TMP/wrapped.yml" config --format json --no-interpolate --no-normalize
            --no-consistency --no-path-resolution --no-env-resolution)
      ;;
    env)
      LC_ALL=C sed -e 's/\$/$$/g' -e 's/^<redacted: line exceeds 8192 bytes>$/#/' "$in" > "$CEV_TMP/escaped.env" \
        || { cev_fail 11 "it cannot be copied"; exit; }
      ej="$(cev_jstr "$CEV_TMP/escaped.env")" || { cev_fail 11 "the temp path holds a control character"; exit; }
      printf '{"name":"lucairn-env-probe","services":{"probe":{"image":"lucairn-env-probe","env_file":[{"path":"%s","required":true}]}}}\n' "$ej" > "$CEV_TMP/probe.json"
      args=(-f "$CEV_TMP/probe.json" config --format json)
      ;;
    *) cev_fail 2 "unknown kind: $kind"; exit ;;
  esac
  if ! "${CEV_CMD[@]}" --project-directory "$CEV_TMP" --env-file /dev/null "${args[@]}" > "$out" 2> "$CEV_TMP/err" </dev/null; then
    : > "$out"
    cev_fail 11 "Docker Compose cannot parse it as $kind (its message is not printed: it can quote the file)"; exit
  fi
)
