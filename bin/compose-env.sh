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
#                (stdout: hex-encoded needles, one per line)
#   cev_l3       --env-file F --project-dir D
#                (stdout: `l3<TAB>NAME<TAB><file state><TAB><effective state>`
#                per L3 shield setting, states only — K-E fix round 1)
#   cev_volume   --env-file F --project-dir D -- <compose args>
#                (stdout: `volume<TAB><registry volume name>`; K-E fix round 2)
#   cev_to_json  yaml|env <file> <outdir> <sentinels>  (support-bundle's
#                exact decoded scan)
# rc: 0 done · 10 Docker Compose is not available (fail closed) · 11 Compose
# refuses customer.env · 12 Compose output this file cannot use · 13 a secret
# value is too short to be searched for (cev_needles) · 2 usage.
# On rc != 0 a value-free reason is on stderr, as `compose-env: <reason>`.
# Both run in a subshell: their private temp directory (the rendered JSON
# holds secrets; mode 0700) is always removed.

CEV_DSN_TARGET="/run/secrets/sanitizer-core/registry-dsn"
# The settings that turn the L3 deep PII shield on (bin/lucairn
# doctor_l3_config), in the order the doctor names them.
CEV_L3_NAMES="LUCAIRN_L3_AVAILABILITY_POSTURE GATEWAY_L3_CUSTOMER_ALLOWLIST OLLAMA_URL LUCAIRN_L3_ADDR"
CEV_DEFAULT_DSN_FILE="./.secrets/sanitizer-core/registry-dsn"

# The JSON reader. Modes (awk -v mode=...):
#   keys      file 1 = file view: the env names Compose can interpolate
#   registry  files: file view, interpolation view, [project]; -v dsnfile,
#             -v projdir, -v given, -v checkfile, -v printdsn
#   needles   files: file view, interpolation view, [project]; then the
#             DSN files named by -v dsnfiles (newline-separated)
#   l3        files: file view, interpolation view; -v l3names (space-separated)
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
function userinfo(v, name,    s, m, pw) {   # every scheme://user:password@ password in v
  s = v
  while (match(s, /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^:\/@ \t\n]*:[^@ \t\n]*@/)) {
    m = substr(s, RSTART, RLENGTH)
    sub(/^[^:]*:\/\/[^:]*:/, "", m); sub(/@$/, "", m)
    if (m != "") { addval(m, "the URL password in " name); addval(pctdec(m), "the URL password in " name) }
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
# Every secret value with the name it came from (the name is reported when the
# value cannot be scanned for; the value never is).
function addval(v, name) { if (v != "" && v != BAD) { vals[++nv] = v; vname[nv] = name } }
function readfile(f,    l, s, n) {      # the DSN file as the core reads it (BOM, TrimSpace)
  s = ""; n = 0
  while ((getline l < f) > 0) { s = s (n++ ? "\n" : "") l }
  close(f)
  if (substr(s, 1, 3) == "\357\273\277") s = substr(s, 4)
  sub(/^[ \t\r\n\v\f]+/, "", s); sub(/[ \t\r\n\v\f]+$/, "", s)
  return s
}
function scalar(p, k, tok, isstr,    v, svc, vk) {
  if (mode == "volume") {               # one file: the install project
    if (p == "services/" volsvc) svcseen = 1
    else if (index(p, "services/" volsvc "/volumes/#") == 1 && (k == "type" || k == "source" || k == "target")) { dm[p, k] = tok; dms[p] = 1 }
    else if (p ~ /^volumes\/[^\/]+$/ && k == "name") { vk = substr(p, 9); vn[vk] = tok; vnset[vk] = 1 }
    return
  }
  if (fno == 1 || fno == 2) {
    if (p != "services/probe/environment") return
    if (mode == "keys") { if (k ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print k; return }
    if (fno == 1) { A[k] = tok; Aset[k] = 1 } else { B[k] = tok; Bset[k] = 1 }
    if (mode == "needles" && isstr) { v = jdec(tok); userinfo(v, k); if (secretname(k)) addval(v, k) }
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
    if (isstr) { v = jdec(tok); userinfo(v, svc "/" k); if (secretname(k)) addval(v, svc "/" k) }
    return
  }
  if (p ~ /^services\/sanitizer-core\/volumes\/#[0-9]+$/ && (k == "source" || k == "target")) {
    vol[p, k] = tok; vols[p] = 1
  }
  if (mode == "needles" && isstr) userinfo(jdec(tok), p)
}
# The state of one L3 shield setting, never its value (OLLAMA_URL can carry
# credentials): the posture as unset | degrade | reject | other (trimmed and
# lower-cased, as the sanitizer reads it), any other name as unset | set;
# `unreadable` when the Compose output cannot be decoded.
function l3state(k, v) {
  if (v == BAD) return "unreadable"
  if (k == "LUCAIRN_L3_AVAILABILITY_POSTURE") {
    v = tolower(v); gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", v)
    if (v == "") return "unset"
    return (v == "reject" || v == "degrade") ? v : "other"
  }
  return (v == "") ? "unset" : "set"
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
  if (mode == "volume") {
    if (!svcseen) { print "why\tthe project has no " volsvc " service"; exit 12 }
    n = 0
    for (m in dms) if (jdec(dm[m, "target"]) == datadir) { n++; src = jdec(dm[m, "source"]); typ = jdec(dm[m, "type"]) }
    if (n != 1) { print "why\t" volsvc " has " n " mounts at " datadir " (one named volume expected)"; exit 12 }
    if (typ != "volume") { print "why\t" volsvc " keeps its data in a " (typ ~ /^[a-z]+$/ ? typ : "non-volume") " mount at " datadir ", not in a named volume"; exit 12 }
    if (src == BAD || src == "" || !vnset[src]) { print "why\tthe project declares no volume for the " volsvc " data mount"; exit 12 }
    v = jdec(vn[src])
    if (v == BAD || v !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/) { print "why\tthe name of volume " src " is not resolved (it holds a ${...} Docker Compose did not interpolate)"; exit 12 }
    print "volume\t" v
    exit 0
  }
  if (mode == "l3") {
    print "compose\tok"
    nl = split(l3names, L, " ")
    for (i = 1; i <= nl; i++)
      print "l3\t" L[i] "\t" l3state(L[i], Aset[L[i]] ? jdec(A[L[i]]) : "") "\t" l3state(L[i], Bset[L[i]] ? jdec(B[L[i]]) : "")
    exit 0
  }
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
  for (f in dsnf) if (index(readable, "\n" f "\n")) { d = readfile(f); if (d != "") { addval(d, "the registry DSN file"); userinfo(d, "the registry DSN file") } }
  # The DECODED values only (K-A fix round 4, sol r3): no escaped or encoded
  # variant is generated here. support-bundle parses every collected file with
  # the parser of its format and compares decoded strings against these
  # (bin/lucairn support_bundle_decoded_scan); the raw byte scan of the same
  # list is the first layer.
  for (i = 1; i <= nv; i++) {
    v = vals[i]
    if (v ~ /^(\/|\.\/|\.\.\/|~\/)/) continue
    frag(v, vname[i])
  }
}
function hex(s,    i, o) { o = ""; for (i = 1; i <= length(s); i++) o = o sprintf("%02x", ord[substr(s, i, 1)]); return o }
# K-A fix round 5 (sol r4 on PR #158): the WHOLE value is always a needle —
# as written, with its line breaks as LF and as CRLF — and every line of a
# multi-line value that has 12+ bytes is one too. A value below 12 bytes
# yields no needle; it is reported BY NAME (`s<TAB>name`) and cev_needles
# fails, so the bundle is refused instead of archived unchecked. Needles are
# printed hex-encoded (`n<TAB>hex`): a value may hold a line feed.
function frag(s, name,    n, a, i, l, t, u) {
  if (length(s) < 12) { print "s\t" name; return }
  print "n\t" hex(s)
  t = s; gsub(/\r\n/, "\n", t); print "n\t" hex(t)
  u = t; gsub(/\n/, "\r\n", u); print "n\t" hex(u)
  n = split(t, a, "\n")
  if (n > 1) for (i = 1; i <= n; i++) { l = a[i]; if (length(l) >= 12) print "n\t" hex(l) }
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
# $3 = "all" (every interpolable key of the file), "registry" or "l3" (the
# registry keys plus CEV_L3_NAMES).
cev_probes() {
  local env="$1" pd="$2" which="$3" abs ej k keys first seenk=""
  case "$env" in /*) abs="$env" ;; *) abs="$PWD/$env" ;; esac
  ej="$(cev_jstr "$abs")" || { cev_fail 11 "the env file path holds a control character"; return; }
  printf '{"name":"lucairn-env-probe","services":{"probe":{"image":"lucairn-env-probe","env_file":[{"path":"%s","required":true}]}}}\n' "$ej" > "$CEV_TMP/probe-a.json"
  if ! cev_render "$CEV_TMP/a.json" "$env" "$pd" -f "$CEV_TMP/probe-a.json"; then
    cev_fail 11 "Docker Compose cannot read $env: $CEV_REASON"; return
  fi
  keys="POSTGRES_SANITIZER_CORE_PASSWORD POSTGRES_SSLMODE SANITIZER_CORE_REGISTRY_DSN_FILE"
  [ "$which" != l3 ] || keys="$keys $CEV_L3_NAMES"
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

# cev_l3 ... — the L3 shield settings as Docker Compose sees them, for the
# keyed doctor's L3-off PARTIAL exception (kit 2.0 K-E fix round 1, review P2
# on PR #162: doctor read the raw file, so a posture exported in the shell —
# which Compose interpolates over customer.env — was missed). One line per
# CEV_L3_NAMES entry: `l3<TAB>NAME<TAB><file view state><TAB><interpolation
# view state>` (l3state above; states only, never a value).
cev_l3() (
  cev_args "$@" || exit
  cev_compose_cmd || exit
  cev_tmp || exit
  trap 'rm -rf "$CEV_TMP"' EXIT
  cev_probes "$CEV_OPT_ENV" "$CEV_OPT_PD" l3 || exit
  LC_ALL=C awk -v mode=l3 -v l3names="$CEV_L3_NAMES" "$CEV_AWK" "$CEV_TMP/a.json" "$CEV_TMP/b.json" \
    || cev_fail 12 "\`docker compose config --format json\` gave output this kit cannot read (Docker Compose v2 is required)"
)

# cev_volume --env-file F --project-dir D -- <compose args> — the Docker
# volume the sanitizer core's registry database (postgres-sanitizer-core)
# keeps its data in, named as Docker Compose names it for the install project
# the compose args describe: the project name (directory, COMPOSE_PROJECT_NAME,
# a top-level `name:`) and a custom or external volume `name:` included (kit
# 2.0 K-E fix round 2, review P2 on PR #162). stdout: `volume<TAB><name>` and
# `render<TAB>interpolated|uninterpolated`. The project renders with the env
# file first; when Compose refuses that (a setting the env does not hold yet:
# upgrade step 4 adds the registry secrets, a fresh install has no env yet),
# it renders again with --no-interpolate, where a name that holds a `${...}`
# stays unresolved and fails. A data mount that is not exactly one named
# volume fails too. rc: 0 · 10 no Docker Compose · 11 Compose refuses the
# project · 12 no name can be resolved (value-free reason) · 2 usage.
cev_volume() (
  cev_args "$@" || exit
  [ "${#CEV_ARGS[@]}" -gt 0 ] || { cev_fail 2 "the install's compose files (after --) are required"; exit; }
  cev_compose_cmd || exit
  cev_tmp || exit
  trap 'rm -rf "$CEV_TMP"' EXIT
  local how=interpolated out
  if ! "${CEV_CMD[@]}" "${CEV_ARGS[@]}" --env-file "$CEV_OPT_ENV" config --format json \
       > "$CEV_TMP/p.json" 2> "$CEV_TMP/err" </dev/null; then
    how=uninterpolated
    if ! "${CEV_CMD[@]}" "${CEV_ARGS[@]}" --env-file "$CEV_OPT_ENV" config --format json --no-interpolate \
         > "$CEV_TMP/p.json" 2> "$CEV_TMP/err" </dev/null; then
      cev_fail 11 "Docker Compose cannot render this install's project: $(cev_reason "$CEV_TMP/err")"; exit
    fi
  fi
  out="$(LC_ALL=C awk -v mode=volume -v volsvc=postgres-sanitizer-core -v datadir=/var/lib/postgresql/data \
           "$CEV_AWK" "$CEV_TMP/p.json")" || true
  case "$out" in
    "volume	"*) printf '%s\nrender\t%s\n' "$out" "$how" ;;
    "why	"*) cev_fail 12 "${out#why	}" ;;
    *) cev_fail 12 "\`docker compose config --format json\` gave output this kit cannot read (Docker Compose v2 is required)" ;;
  esac
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
  # A secret that yields no needle is never left unchecked (K-A fix round 5).
  local short
  short="$(LC_ALL=C sed -n 's/^s	//p' "$CEV_TMP/needles" | LC_ALL=C sort -u | LC_ALL=C tr -c 'A-Za-z0-9_./ \n-' '?' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  if [ -n "$short" ]; then
    cev_fail 13 "a secret value is shorter than 12 characters, so it cannot be searched for in the collected files ($short); a longer value (bin/lucairn-init generates 32+) makes the bundle possible"; exit
  fi
  LC_ALL=C sed -n 's/^n	//p' "$CEV_TMP/needles" | LC_ALL=C sort -u
)

# cev_to_json <yaml|env> <in> <outdir> <sentinel>... — one support-bundle file,
# decoded by Docker Compose's OWN parsers into JSON files under <outdir>, in
# the shapes bin/lucairn support_bundle_decoded_scan needs to prove that the
# decoded view is EXACTLY the file's text (K-A fix round 5, sol r4 on PR #158:
# a decoder that drops content — a YAML merge an explicit key overrides, a
# `!reset` tag, an env assignment overwritten later, a `$` Compose
# interpolates — let an escaped secret through both scans). Nothing here
# parses the file by hand: every view is Compose's, and the scanner refuses
# the bundle whenever two views that must agree do not.
#   yaml <in> <outdir> <merge sentinel> <tag sentinel>
#         The file's lines, each indented two spaces under ONE top-level
#         `x-lucairn-bundle-scan:` key (Compose passes `x-` content through
#         unvalidated, so its YAML parser decodes ANY document — quoting, ''
#         and "\x41" escapes, folding, anchors — and nothing in it is
#         interpreted as a project), rendered --no-interpolate, TWICE:
#           merge.json  every `<<` replaced by the merge sentinel (an
#                       alphanumeric token the file does not contain): a merge
#                       key becomes an ordinary key, so the merged mapping AND
#                       every key that would override it are both kept —
#                       nothing a merge discards is lost;
#           tags.json   as merge.json, and every `!` replaced by the tag
#                       sentinel: a tag becomes plain text. A file without a
#                       tag decodes identically (a `!` anywhere else is
#                       literal text in YAML); a file with one does not
#                       (`!reset` drops a value, `!!binary` rewrites it, any
#                       tag can) — the scanner refuses it, naming the file.
#         A document marker (---, ...) or directive (%) line cannot sit under
#         one key: refused (rc 11). redact_stream's whole-line marker for a
#         line over 8 KiB carries no data and becomes a comment.
#   env <in> <outdir> <dollar sentinel> <octal sentinel>
#         Compose's dotenv parser (quotes, escapes, `export`, comments,
#         multi-line values), with no `$` doubling (doubling changes a valid
#         value: `"\$x"` would become an interpolated `$x`):
#           whole.json  the file as it is (one probe service, env_file: <in>);
#           lines.json  every line on its own, twice: service o<N> = line N
#                       as written, service s<N> = line N with every `$`
#                       and every `\0` (the only escape that yields a `$`,
#                       e.g. "\0044") replaced by the sentinels.
#         The scanner requires: line N alone == line N in the file (no value
#         spans lines), each variable assigned on ONE line (no assignment
#         overwritten later), o<N> == s<N> with the sentinels put back (the
#         value is the text as written — no interpolation, no `\$`, no octal
#         escape in double quotes). Blank and `#` comment lines get no service.
#         A line Compose refuses on its own: rc 11, naming the line.
# rc: 0 · 10 no Docker Compose · 11 Compose refused the file · 2 usage.
# Runs in a subshell; its private temp directory (mode 0700) is removed.
cev_to_json() (
  local kind="$1" in="$2" out="$3" ej n
  [ -f "$in" ] && [ ! -L "$in" ] || { cev_fail 2 "not a regular file"; exit; }
  [ -d "$out" ] || { cev_fail 2 "no output directory"; exit; }
  cev_compose_cmd || exit
  cev_tmp || exit
  trap 'rm -rf "$CEV_TMP"' EXIT
  case "$kind" in
    yaml)
      local sm="${4:-}" st="${5:-}"
      case "$sm$st" in *[!A-Za-z0-9]*|"") cev_fail 2 "the sentinels must be alphanumeric"; exit ;; esac
      LC_ALL=C awk '
        NR == 1 { print "x-lucairn-bundle-scan:"; sub(/^\357\273\277/, "") }
        /^(---|\.\.\.)([ \t\r]|$)/ || /^%/ { bad = NR; exit }
        $0 == "<redacted: line exceeds 8192 bytes>" { print "  #"; next }
        { print "  " $0 }
        END { if (bad) { print "line " bad > "/dev/stderr"; exit 1 } if (NR == 0) print "x-lucairn-bundle-scan:" }
      ' "$in" > "$CEV_TMP/wrapped.yml" 2> "$CEV_TMP/wrap.err" \
        || { cev_fail 11 "$(cat "$CEV_TMP/wrap.err"): a YAML document marker or directive (it cannot be decoded as one document)"; exit; }
      LC_ALL=C sed "s/<</$sm/g" "$CEV_TMP/wrapped.yml" > "$CEV_TMP/merge.yml"
      LC_ALL=C sed "s/!/$st/g" "$CEV_TMP/merge.yml" > "$CEV_TMP/tags.yml"
      for n in merge tags; do
        if ! "${CEV_CMD[@]}" --project-directory "$CEV_TMP" --env-file /dev/null -f "$CEV_TMP/$n.yml" config --format json \
             --no-interpolate --no-normalize --no-consistency --no-path-resolution --no-env-resolution \
             > "$out/$n.json" 2> "$CEV_TMP/err" </dev/null; then
          : > "$out/$n.json"
          cev_fail 11 "$(cev_yaml_reason "$CEV_TMP/err")"; exit
        fi
      done
      ;;
    env)
      local sd="${4:-}" so="${5:-}"
      case "$sd$so" in *[!A-Za-z0-9]*|"") cev_fail 2 "the sentinels must be alphanumeric"; exit ;; esac
      mkdir -p "$CEV_TMP/l" || { cev_fail 11 "cannot create a private temp directory"; exit; }
      LC_ALL=C sed -e 's/^<redacted: line exceeds 8192 bytes>$/#/' "$in" > "$CEV_TMP/whole.env" \
        || { cev_fail 11 "it cannot be copied"; exit; }
      ej="$(cev_jstr "$CEV_TMP/whole.env")" || { cev_fail 11 "the temp path holds a control character"; exit; }
      printf '{"name":"lucairn-env-probe","services":{"probe":{"image":"lucairn-env-probe","env_file":[{"path":"%s","required":true}]}}}\n' "$ej" > "$CEV_TMP/whole.json"
      # One service per non-comment line, as written (o) and neutralised (s).
      LC_ALL=C awk -v d="$CEV_TMP/l" -v sd="$sd" -v so="$so" '
        BEGIN { printf "{\"name\":\"lucairn-env-probe\",\"services\":{\"probe\":{\"image\":\"lucairn-env-probe\"}" }
        /^[[:space:]]*(#|$)/ { next }
        {
          o = d "/o" NR ".env"; s = d "/s" NR ".env"
          print $0 > o; close(o)
          t = $0; gsub(/\$/, sd, t); gsub(/\\0/, so, t)
          print t > s; close(s)
          printf ",\"o%d\":{\"image\":\"lucairn-env-probe\",\"env_file\":[{\"path\":\"l/o%d.env\",\"required\":true}]}", NR, NR
          printf ",\"s%d\":{\"image\":\"lucairn-env-probe\",\"env_file\":[{\"path\":\"l/s%d.env\",\"required\":true}]}", NR, NR
        }
        END { printf "}}\n" }
      ' "$CEV_TMP/whole.env" > "$CEV_TMP/lines.json" || { cev_fail 11 "it cannot be split into lines"; exit; }
      if ! "${CEV_CMD[@]}" --project-directory "$CEV_TMP" --env-file /dev/null -f "$CEV_TMP/whole.json" config --format json \
           > "$out/whole.json" 2> "$CEV_TMP/err" </dev/null; then
        : > "$out/whole.json"
        cev_fail 11 "Docker Compose's env-file parser refuses it$(cev_env_line "$CEV_TMP/err" whole)"; exit
      fi
      if ! "${CEV_CMD[@]}" --project-directory "$CEV_TMP" --env-file /dev/null -f "$CEV_TMP/lines.json" config --format json \
           > "$out/lines.json" 2> "$CEV_TMP/err" </dev/null; then
        : > "$out/lines.json"
        cev_fail 11 "Docker Compose cannot read$(cev_env_line "$CEV_TMP/err" lines) on its own (a value that spans lines, or a line Compose refuses): it cannot be decoded line by line"; exit
      fi
      ;;
    *) cev_fail 2 "unknown kind: $kind"; exit ;;
  esac
)

# A value-free reason for a YAML file Compose refused: the line (of the
# collected file, not the wrapper) and the construct when Compose names one;
# never Compose's message (it can quote the file).
cev_yaml_reason() {
  local l what="Docker Compose's YAML parser refuses it"
  if LC_ALL=C grep -q 'already defined' "$1"; then
    what="a duplicate mapping key (a value defined twice; only one would be decoded)"
    l="$(LC_ALL=C sed -n 's/.*line \([0-9][0-9]*\): mapping key .*already defined.*/\1/p' "$1" | head -1)"
  else
    l="$(LC_ALL=C sed -n -e 's/.* at L\([0-9][0-9]*\)\.C.*/\1/p' -e 's/.*line \([0-9][0-9]*\):.*/\1/p' "$1" | head -1)"
  fi
  if [ -n "$l" ] && [ "$l" -gt 1 ]; then printf 'line %s: %s' "$((l - 1))" "$what"; else printf '%s' "$what"; fi
}

# " line N" for an env file Compose refused (from the per-line probe's file
# name or Compose's own line number), or "" — never Compose's message.
cev_env_line() {
  local l
  if [ "$2" = lines ]; then
    l="$(LC_ALL=C sed -n 's/.*\/l\/[os]\([0-9][0-9]*\)\.env.*/\1/p' "$1" | head -1)"
    if [ -n "$l" ]; then printf ' line %s' "$l"; else printf ' a line'; fi
  else
    l="$(LC_ALL=C sed -n 's/.*: line \([0-9][0-9]*\):.*/\1/p' "$1" | head -1)"
    [ -z "$l" ] || printf ' (line %s)' "$l"
  fi
}
