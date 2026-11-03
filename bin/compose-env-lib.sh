#!/usr/bin/env bash
# compose-env-lib.sh — read a value from a Compose env file (customer.env)
# the way Docker Compose reads it. Sourced by bin/lucairn (doctor,
# support-bundle), bin/lucairn-init and scripts/write-sanitizer-core-registry-dsn.sh:
# ONE reader, so the DSN writer and the doctor can never disagree about what a
# value is (kit 2.0 K-A fix round 1, sol r1 finding 1: the old per-line reader
# stripped a lone trailing quote that Compose keeps, so
# POSTGRES_SANITIZER_CORE_PASSWORD="BoundaryProbe4829'" passed validation as
# BoundaryProbe4829 while Postgres got the apostrophe).
#
# Bash 3.2 + POSIX awk (onetrue-awk, mawk, gawk, busybox), byte semantics.
#
# THE RULES (Docker Compose v5.4.0 embeds compose-go v2.14.0, verified with
# `go version -m docker-compose`; source dotenv/parser.go at tag v2.14.0;
# user-facing summary: https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/#env-file-syntax):
#   * the whole file is ONE token stream, not a list of lines: a quoted value
#     may run over several lines, so a `KEY=` at the start of a line inside it
#     is not a statement (parse, L33-72);
#   * a leading UTF-8 byte-order mark is dropped (godotenv.go L56-58);
#   * white space (unicode.IsSpace) and `#` comment lines between statements
#     are skipped (getStatementStart, L77-94);
#   * an optional `export` + white space prefix is dropped (L100-105);
#   * the name runs to the first `=` or `:` (YAML style) or a line end (a
#     bare name = "take it from the environment"); spaces around it are
#     dropped; any character other than letters, digits, `_ . - [ ]` and
#     spaces is an error that makes Compose refuse the file; a name with an
#     inner space is an error too (L49-51, L107-146);
#   * white space after the separator is skipped (L145, isSpace L280-286);
#   * a value that STARTS with `"` or `'` runs to the next UNESCAPED quote of
#     the same kind: `\<quote>` keeps the quote, every other backslash pair is
#     kept as written; no closing quote = Compose refuses the file. So ONLY a
#     matching pair of OUTER quotes is removed — `"abc'` is an error and
#     `abc'` keeps its quote. Whatever follows the closing quote is read as
#     the next statement (`"x" # note` = a comment) (L164-213);
#   * a double-quoted value then gets escape sequences (`\n`, `\t`, `\\`,
#     `\0NNN` octal, …) and `$`-interpolation; a single-quoted value gets
#     neither (L194-202, L216-246);
#   * an unquoted value runs to the line end, is cut at the first ` #`
#     (space + hash), loses trailing white space, and gets `$`-interpolation
#     (L152-162);
#   * the LAST assignment of a name wins (L67).
#   * The SHELL wins over the file: a variable exported in the environment
#     that runs `docker compose` overrides customer.env for interpolation
#     (cli/options.go L240-248 + L300-306, measured with Compose v5.4.0).
#     compose_env_shell_override below reports that case.
#
# What this reader does NOT evaluate, and so refuses (rc 3) for the asked key
# instead of guessing: `$`-interpolation (unquoted and double-quoted values)
# and backslash escape sequences in double-quoted values (`"\0101"` is "A" to
# Compose). Every value the sanitizer core reads from customer.env refuses `$`
# and `\` anyway, so this costs nothing. A name holding a non-ASCII character
# (Compose accepts Unicode letters; this byte-level reader cannot classify
# them) is rc 3 as well.
#
# NON-COVERAGE: interpolation errors in OTHER values (`${X:?msg}` with X unset)
# make Compose refuse the file at render time; this reader does not see them
# (the stack then does not start at all). Multiple --env-file files are not
# merged here: the kit passes exactly one.
#
# tests/test_sanitizer_core_compose.sh section D3 runs this reader and Docker
# Compose itself over the same corpus and requires identical answers.

# compose_env_get <env file> <KEY>
#   rc 0  the value Compose reads from the file (empty = unset or empty)
#   rc 1  the file is missing, not a regular file, or unreadable
#   rc 2  Compose would refuse the file (a syntax error anywhere in it)
#   rc 3  the value of KEY (its last assignment) uses a construct this reader
#         does not evaluate, or a name it cannot classify
# On rc 1-3 stdout carries a reason that never contains a value.
compose_env_get() {
  local file="$1" key="$2" final_nl=0 size nonul
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'the env file is missing, not a regular file, or not readable'
    return 1
  fi
  size="$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d ' ')"
  nonul="$(LC_ALL=C tr -d '\000' < "$file" 2>/dev/null | LC_ALL=C wc -c | tr -d ' ')"
  if [ "${size:-0}" != "${nonul:-0}" ]; then
    printf 'the env file holds a NUL byte'
    return 3
  fi
  if [ "${size:-0}" -gt 0 ] && [ -z "$(LC_ALL=C tail -c 1 "$file" | LC_ALL=C tr -d '\n')" ]; then
    final_nl=1
  fi
  LC_ALL=C awk -v want="$key" -v final_nl="$final_nl" '
    function isspace_len(s, i,    c, c2) {
      # dotenv isSpace: \t \v \f \r space, U+0085, U+00A0 (not \n)
      c = substr(s, i, 1)
      if (c == "\t" || c == "\013" || c == "\014" || c == "\r" || c == " ") return 1
      if (c == "\302") {
        c2 = substr(s, i + 1, 1)
        if (c2 == "\205" || c2 == "\240") return 2
      }
      return 0
    }
    function unispace_len(s, i,    c, c2, c3, l) {
      # unicode.IsSpace: isSpace + \n + U+1680, U+2000-U+200A, U+2028,
      # U+2029, U+202F, U+205F, U+3000 (UTF-8 sequences)
      c = substr(s, i, 1)
      if (c == "\n") return 1
      l = isspace_len(s, i)
      if (l) return l
      if (c == "\341" && substr(s, i + 1, 2) == "\232\200") return 3
      if (c == "\342") {
        c2 = substr(s, i + 1, 1); c3 = substr(s, i + 2, 1)
        if (c2 == "\200" && c3 != "" && index("\200\201\202\203\204\205\206\207\210\211\212\250\251\257", c3) > 0) return 3
        if (c2 == "\201" && c3 == "\237") return 3
      }
      if (c == "\343" && substr(s, i + 1, 2) == "\200\200") return 3
      return 0
    }
    function rtrim_unispace(s,    n, t, c2, c3) {
      while ((n = length(s)) > 0) {
        t = substr(s, n, 1)
        if (t == "\n" || t == "\t" || t == "\013" || t == "\014" || t == "\r" || t == " ") { s = substr(s, 1, n - 1); continue }
        if (n >= 2) {
          c2 = substr(s, n - 1, 2)
          if (c2 == "\302\205" || c2 == "\302\240") { s = substr(s, 1, n - 2); continue }
        }
        if (n >= 3) {
          c3 = substr(s, n - 2, 3)
          if (c3 == "\341\232\200" || c3 == "\342\200\250" || c3 == "\342\200\251" || c3 == "\342\200\257" || c3 == "\342\201\237" || c3 == "\343\200\200") { s = substr(s, 1, n - 3); continue }
          if (substr(c3, 1, 2) == "\342\200" && index("\200\201\202\203\204\205\206\207\210\211\212", substr(c3, 3, 1)) > 0) { s = substr(s, 1, n - 3); continue }
        }
        break
      }
      return s
    }
    function lineno(pos,    i, l) {
      l = 1
      for (i = 1; i < pos && i <= n; i++) if (substr(src, i, 1) == "\n") l++
      return l
    }
    function refuse(rc, msg) { printf "%s", msg; exit rc }
    BEGIN {
      ascii = ""
      for (k = 1; k < 128; k++) ascii = ascii sprintf("%c", k)
    }
    { lines[NR] = $0 }
    END {
      src = ""
      for (k = 1; k <= NR; k++) {
        src = src lines[k]
        if (k < NR || final_nl == 1) src = src "\n"
      }
      if (substr(src, 1, 3) == "\357\273\277") src = substr(src, 4)
      n = length(src); p = 1
      found = 0; val = ""; unsup = 0
      while (1) {
        # getStatementStart: white space and # comment lines
        while (p <= n) {
          l = unispace_len(src, p)
          if (l) { p += l; continue }
          if (substr(src, p, 1) == "#") {
            q = index(substr(src, p), "\n")
            if (q == 0) { p = n + 1; break }
            p = p + q - 1
            continue
          }
          break
        }
        if (p > n) break
        st = p
        # export prefix: ^export\s+ (RE2 \s = [\t\n\f\r ])
        if (substr(src, p, 6) == "export") {
          c = substr(src, p + 6, 1)
          if (c == "\t" || c == "\n" || c == "\014" || c == "\r" || c == " ") {
            p += 6
            while ((l = isspace_len(src, p)) > 0) p += l
            if (p > n) refuse(2, "line " lineno(st) ": a bare export (zero length statement)")
          }
        }
        ks = p; sep = ""
        while (p <= n) {
          l = isspace_len(src, p)
          if (l) { p += l; continue }
          c = substr(src, p, 1)
          if (c == "=" || c == ":" || c == "\n") { sep = c; break }
          if (c ~ /[A-Za-z0-9_.-]/ || c == "[" || c == "]") { p++; continue }
          if (index(ascii, c) == 0) refuse(3, "line " lineno(p) ": a variable name holds a non-ASCII character (Compose may accept it; this reader does not classify it)")
          refuse(2, "line " lineno(p) ": unexpected character in a variable name (Docker Compose refuses this file)")
        }
        if (sep == "") break   # a name with no separator at the end of the file: assigns nothing to a named key
        key = rtrim_unispace(substr(src, ks, p - ks))
        if (index(key, " ") > 0) refuse(2, "line " lineno(ks) ": a variable name holds a space (Docker Compose refuses this file)")
        p++
        while ((l = isspace_len(src, p)) > 0) p += l
        if (sep == "\n") continue   # bare name: inherited from the environment (see compose_env_shell_override)
        c = substr(src, p, 1)
        flag = 0
        if (c == "\"" || c == "\047") {
          qc = c; prev = 0; buf = ""; closed = 0
          for (i = p + 1; i <= n; i++) {
            ch = substr(src, i, 1)
            if (ch != qc) {
              if (!prev && ch == "\\") { prev = 1; continue }
              if (prev) { prev = 0; buf = buf "\\" }
              buf = buf ch
              continue
            }
            if (prev) { prev = 0; buf = buf ch; continue }
            closed = 1
            break
          }
          if (!closed) refuse(2, "line " lineno(p) ": unterminated quoted value (Docker Compose refuses this file)")
          v = buf
          p = i + 1
          if (qc == "\"" && (index(v, "\\") > 0 || index(v, "$") > 0)) flag = 1
        } else {
          e = index(substr(src, p), "\n")
          if (e) { v = substr(src, p, e - 1); p = p + e } else { v = substr(src, p); p = n + 1 }
          h = index(v, " #")
          if (h) v = substr(v, 1, h - 1)
          v = rtrim_unispace(v)
          if (index(v, "$") > 0) flag = 1
        }
        if (key == want) { found = 1; val = v; unsup = flag }
      }
      if (found && unsup) refuse(3, want " uses $-interpolation or a backslash escape, which this reader does not evaluate (write the literal value)")
      printf "%s", val
      exit 0
    }
  ' "$file"
}

# compose_env_shell_override <KEY> <file value>
#   rc 0 when KEY is exported in THIS process environment with a value other
#   than <file value>: Docker Compose, run from this shell, would use the
#   exported value instead of customer.env (cli/options.go WithOsEnv runs
#   before WithDotEnv and Merge keeps the first value). Never prints a value.
compose_env_shell_override() {
  local key="$1" file_val="$2" shell_val
  case "$key" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  eval "[ \"\${$key+set}\" = set ]" || return 1
  eval "shell_val=\"\${$key}\""
  [ "$shell_val" != "$file_val" ]
}
