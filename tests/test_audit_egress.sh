#!/usr/bin/env bash
# T-1273: offline egress inventory, transparent forwarding and lifecycle checks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 - "$ROOT" "${1:-}" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

# Bound the entire suite as well as each client, subprocess and socket.
signal.signal(signal.SIGALRM, lambda *_: sys.exit("FAIL: audit suite timed out"))
signal.alarm(60)
root = Path(sys.argv[1])
cli = str(root / "bin/lucairn")
spec = importlib.util.spec_from_file_location("audit_egress", root / "bin/lucairn-audit-egress.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


# These checks need no sockets and remain runnable in a bind-restricted sandbox.
import contextlib
import io
from unittest.mock import Mock, call, patch

assert audit.endpoint("https://GATEWAY.example.test.:8443/base") == ("gateway.example.test", 8443)
assert audit.endpoint("[::1]:443", connect=True) == ("::1", 443)
for invalid in ("http://user:SENTINEL@host", "http://host:0", "http://host:65536",
                "http://host/#SENTINEL", "http://host\n", "http:///", "SENTINEL"):
    try:
        audit.endpoint(invalid)
    except ValueError:
        pass
    else:
        raise AssertionError("invalid endpoint accepted")

class MemorySocket:
    def __init__(self, incoming=b""):
        self.input = io.BytesIO(incoming)
        self.output = bytearray()
    def makefile(self, *args, **kwargs):
        return self.input
    def sendall(self, data):
        self.output.extend(data)
    def close(self):
        pass

for payload, fields in (
    (b"SENTINEL", {b"content-length": b"8"}),
    (b"8\r\nSENTINEL\r\n0\r\nX-Fixture: SENTINEL\r\n\r\n", {b"transfer-encoding": b"chunked"}),
):
    sink = MemorySocket()
    assert audit.body(io.BytesIO(payload), sink, fields)
    assert bytes(sink.output) == payload
for payload, fields in (
    (b"", {b"content-length": b"-1"}),
    (b"short", {b"content-length": b"9"}),
    (b"", {b"content-length": b"8", b"transfer-encoding": b"chunked"}),
    (b"8\r\nshort", {b"transfer-encoding": b"chunked"}),
):
    try:
        audit.body(io.BytesIO(payload), MemorySocket(), fields)
    except ValueError:
        pass
    else:
        raise AssertionError("bad body framing accepted")

# Construct the real server state without its socketserver bind step.
def memory_proxy():
    proxy = object.__new__(audit.Forwarder)
    proxy.started = time.monotonic()
    proxy.deadline = proxy.started + 5
    proxy.stopped = threading.Event()
    proxy.failed = threading.Event()
    proxy.lock = threading.Lock()
    proxy.inventory = {}
    proxy.track = lambda connection: connection
    proxy.forget = lambda connection: None
    return proxy

request = b"POST http://gateway.example.test/SENTINEL HTTP/1.1\r\nHost: gateway.example.test\r\nContent-Length: 8\r\n\r\nSENTINEL"
response = b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nSENTINEL"
client = MemorySocket(request * 2)
remotes = [MemorySocket(response), MemorySocket(response)]
proxy = memory_proxy()
with patch.object(audit.socket, "create_connection", side_effect=remotes):
    audit.Handler(client, ("127.0.0.1", 1), proxy)
assert bytes(client.output) == response * 2
assert all(bytes(remote.output) == request for remote in remotes)
assert proxy.inventory[("gateway.example.test", 80)]["count"] == 2
assert "SENTINEL" not in json.dumps(list(proxy.inventory.values()))
for method_target in (b"CONNECT gateway.example.test:443", b"GET http://other.example.test/"):
    client = MemorySocket(method_target + b" HTTP/1.1\r\n\r\n")
    proxy = memory_proxy()
    with patch.object(audit.socket, "create_connection", side_effect=OSError("SENTINEL")):
        audit.Handler(client, ("127.0.0.1", 1), proxy)
    assert bytes(client.output).startswith(b"HTTP/1.1 502")
    assert len(proxy.inventory) == 1

# A malformed upstream reply must end only this request, not the audit.
for reply in (b"HTTP/1.1\r\n", b"HTTP/1.1 SENTINEL\r\n", b"HTTP/1.1 99\r\n"):
    proxy = memory_proxy()
    with patch.object(audit.socket, "create_connection", return_value=MemorySocket(reply)):
        audit.Handler(MemorySocket(request), ("127.0.0.1", 1), proxy)
    assert proxy.inventory[("gateway.example.test", 80)]["count"] == 1
    assert not proxy.failed.is_set()

# EPERM and bounded waits must never prevent the KILL attempt or escape cleanup.
for denied in (False, True):
    process = Mock(pid=123)
    process.wait.side_effect = [subprocess.TimeoutExpired("SENTINEL", 0.2),
                                subprocess.TimeoutExpired("SENTINEL", 1)]
    with patch.object(audit.os, "killpg", side_effect=PermissionError() if denied else None) as kill:
        audit.stop_client(process)
    assert kill.call_args_list == [call(123, signal.SIGTERM), call(123, signal.SIGKILL)]
    assert process.wait.call_args_list == [call(timeout=0.2), call(timeout=1)]

# Actual shell launch/output deletion/process-group cleanup with only the
# listener mocked. End-to-end socket checks below remain independently required.
class IdleProxy:
    rows = []
    def __init__(self, started, deadline):
        self.inventory = {(r["host"], r["port"]): dict(r) for r in self.rows}
        self.failed = threading.Event()
        self.stopped = threading.Event()
        self.server_address = ("127.0.0.1", 1)
    def serve_forever(self, **kwargs):
        self.stopped.wait(5)
    def stop(self):
        self.stopped.set()
    def server_close(self):
        self.stop()

base = ["--gateway-url", "http://gateway.example.test", "--command",
        shlex.quote(sys.executable) + " -c " + shlex.quote('import os; print(dict(os.environ))'), "--json"]
gateway_row = {"host": "gateway.example.test", "port": 443, "count": 1, "first_seen_ms": 0}
other_row = dict(gateway_row, host="other.example.test")
for rows, extra, expected, verdict in (
    ([gateway_row, other_row], [], 0, "PASS"),
    ([gateway_row, other_row], ["--expect-host", "allowed.example.test"], 2, "ATTENTION: unexpected hosts"),
    ([other_row], [], 2, "ATTENTION: gateway host not contacted"),
    ([gateway_row, other_row], ["--expect-host", "other.example.test"], 0, "PASS"),
):
    IdleProxy.rows = rows
    output = io.StringIO()
    with patch.object(audit, "Forwarder", IdleProxy), contextlib.redirect_stdout(output):
        assert audit.main(base + extra) == expected
    result = json.loads(output.getvalue())
    assert result["verdict"] == verdict
    assert {r["host"] for r in result["hosts"]} == {r["host"] for r in rows}
    assert set(result) == {"command", "gateway_host", "hosts", "unexpected", "verdict", "duration_ms", "scope", "no_proxy_was_set"}
    assert "SENTINEL_ENV" not in output.getvalue()

# Presence includes empty variables; neither spelling may reach the child.
for inherited in ({}, {"NO_PROXY": "SENTINEL"}, {"no_proxy": "SENTINEL"},
                  {"NO_PROXY": "", "no_proxy": "SENTINEL"}):
    environment = {k: v for k, v in os.environ.items() if k not in ("NO_PROXY", "no_proxy")}
    environment.update(inherited)
    check_env = 'import os; assert "NO_PROXY" not in os.environ and "no_proxy" not in os.environ'
    for json_mode in (False, True):
        output = io.StringIO()
        with patch.dict(os.environ, environment, clear=True), patch.object(audit, "Forwarder", IdleProxy), contextlib.redirect_stdout(output):
            assert audit.main(["--gateway-url", "http://gateway.example.test", "--command",
                               shlex.quote(sys.executable) + " -c " + shlex.quote(check_env)]
                              + (["--json"] if json_mode else [])) == 0
        assert "SENTINEL" not in output.getvalue()
        if json_mode:
            assert json.loads(output.getvalue())["no_proxy_was_set"] is bool(inherited)
        else:
            assert (audit.NO_PROXY_NOTICE in output.getvalue()) is bool(inherited)

for code, status in (("import sys; sys.exit(7)", "client exited 7"),
                     ("import time; time.sleep(30)", "client timed out after 0.1 s")):
    for json_mode in (False, True):
        output, error = io.StringIO(), io.StringIO()
        with patch.object(audit, "Forwarder", IdleProxy), contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            assert audit.main(["--gateway-url", "http://gateway.example.test", "--timeout", "0.1", "--command",
                               shlex.quote(sys.executable) + " -c " + shlex.quote(code)]
                              + (["--json"] if json_mode else [])) == 1
        assert status in error.getvalue()
        if json_mode:
            data = json.loads(output.getvalue())
            assert data["client_status"] == status
            assert {r["host"] for r in data["hosts"]} == {r["host"] for r in IdleProxy.rows}
        else:
            assert status in output.getvalue() and "other.example.test · 443 · 1 · other" in output.getvalue()

with tempfile.TemporaryDirectory(prefix="test-audit-unit-") as directory:
    state = Path(directory) / "pid"
    child_code = 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)'
    parent_code = ('import subprocess,time; p=subprocess.Popen(' + repr([sys.executable, "-c", child_code]) + '); '
                   'open(' + repr(str(state)) + ',"w").write(str(p.pid)); time.sleep(30)')
    def temporary_output(**kwargs):
        return tempfile.NamedTemporaryFile(dir=directory, prefix="captured-output", mode="w+b")
    original_stop = audit.stop_client
    def repeated_interrupts(process):
        if process is not None:
            os.kill(os.getpid(), signal.SIGINT)
            os.kill(os.getpid(), signal.SIGTERM)
        original_stop(process)
    for mode in ("timeout", "interrupt", "leader-exit"):
        state.unlink(missing_ok=True)
        code = parent_code
        if mode == "leader-exit":
            code = parent_code.rsplit(' time.sleep(30)', 1)[0]
        error = io.StringIO()
        timer = None
        try:
            if mode == "interrupt":
                timer = threading.Timer(0.4, lambda: os.kill(os.getpid(), signal.SIGTERM))
                timer.start()
            started = time.monotonic()
            with patch.object(audit, "Forwarder", IdleProxy), patch.object(audit, "stop_client", repeated_interrupts), patch.object(audit.tempfile, "TemporaryFile", temporary_output), contextlib.redirect_stderr(error), contextlib.redirect_stdout(io.StringIO()):
                assert audit.main(["--gateway-url", "http://localhost", "--timeout", "0.7", "--command",
                                   shlex.quote(sys.executable) + " -c " + shlex.quote(code)]) == (2 if mode == "leader-exit" else 1)
            assert time.monotonic() - started < 2
            if mode != "leader-exit":
                assert ("client timed out" if mode == "timeout" else "audit interrupted") in error.getvalue()
            assert not list(Path(directory).glob("captured-output*"))
            pid = int(state.read_text())
            until = time.monotonic() + 1
            while True:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                proc_stat = Path('/proc/{}/stat'.format(pid))
                if proc_stat.exists() and proc_stat.read_text().split()[2] == 'Z':
                    break
                assert time.monotonic() < until, "descendant survived cleanup"
                time.sleep(0.02)
        finally:
            if timer:
                timer.cancel()
                timer.join(timeout=1)
            if state.exists():
                try:
                    os.kill(int(state.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

# Exercise the real Bash env loader and option wiring with a helper-argv spy.
with tempfile.TemporaryDirectory(prefix="test-audit-wrapper-") as directory:
    scratch = Path(directory)
    shim = scratch / "python3"
    shim.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " -c "
                    + shlex.quote("import json,sys; print(json.dumps(sys.argv[1:]))") + ' "$@"\n')
    shim.chmod(0o700)
    environment = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"])
    env_file = scratch / "customer.env"
    env_file.write_text('GATEWAY_BASE_URL="http://gateway.example.test"\nSENTINEL_ENV=visible\n')
    for options, expected_url in (
        ([], "http://gateway.example.test"),
        (["--env", str(env_file)], "http://gateway.example.test"),
        (["--env", str(env_file), "--gateway-url", "http://override.example.test"], "http://override.example.test"),
    ):
        result = subprocess.run([cli, "audit-egress"] + options, cwd=directory,
                                env=environment, capture_output=True, text=True, timeout=2)
        assert result.returncode == 0, result.stderr
        args = json.loads(result.stdout)
        assert args[1:] == ["--gateway-url", expected_url]
        assert "SENTINEL" not in result.stdout
    env_file.unlink()
    for options in ([], ["--env", str(env_file)], ["--gateway-url"], ["--unknown"]):
        result = subprocess.run([cli, "audit-egress"] + options, cwd=directory,
                                env=environment, capture_output=True, text=True, timeout=2)
        assert result.returncode == 1 and result.stdout == ""

print("PASS: audit-egress in-memory forwarding, inventory, verdicts and real process cleanup")
if sys.argv[2] == "--unit-only":
    sys.exit(0)

with tempfile.TemporaryDirectory(prefix="test-audit-egress-") as directory:
    scratch = Path(directory)
    # Enforce offline behavior in every Python child: no DNS or outbound
    # sockets. Synthetic .test targets fail immediately, before resolution.
    (scratch / "sitecustomize.py").write_text('''
import socket
_original = socket.getaddrinfo
def local_only(host, *args, **kwargs):
    if host not in ("127.0.0.1", "::1", "localhost", None):
        raise OSError("offline fixture")
    return _original(host, *args, **kwargs)
socket.getaddrinfo = local_only
_connect = socket.socket.connect
def connect(self, address):
    if not isinstance(address, tuple) or address[0] not in ("127.0.0.1", "::1"):
        raise OSError("offline fixture")
    return _connect(self, address)
socket.socket.connect = connect
''')
    environment = dict(os.environ, PYTHONPATH=directory, TMPDIR=directory,
                       SENTINEL_ENV="visible", SHELL="/bin/sh")
    for name in ("NO_PROXY", "no_proxy"):
        environment.pop(name, None)
    # Deliberately dirty all six proxy variables; each must be replaced.
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        environment[name] = "SENTINEL"

    def command(code):
        return shlex.quote(sys.executable) + " -c " + shlex.quote(code)

    def run(code, *options, expected=0, gateway=True):
        args = [cli, "audit-egress", "--timeout", "5", "--command", command(code)]
        if gateway:
            args += ["--gateway-url", "http://gateway.example.test"]
        started = time.monotonic()
        result = subprocess.run(args + list(options), env=environment, cwd=directory,
                                capture_output=True, text=True, timeout=9)
        assert time.monotonic() - started < 9
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        # stdout/stderr of the synthetic client contain planted private text.
        # The command printed in the report refers to the env by a constructed
        # name so the assertion distinguishes command text from leaked output.
        assert "visible" not in result.stdout + result.stderr
        assert "SENTINEL_ENV" not in result.stdout + result.stderr
        assert not list(scratch.glob("lucairn-audit-egress-*"))
        return result

    prefix = ('import os,socket,sys; from urllib.parse import urlsplit; '
              'p=urlsplit(os.environ["HTTPS_PROXY"]); '
              'assert all(os.environ[n]==p.geturl() for n in '
              '("HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","http_proxy","https_proxy","all_proxy")); '
              'print(dict(os.environ)); print(os.environ["SENTINEL"+"_ENV"],file=sys.stderr); ')

    def contacts(*hosts):
        code = prefix
        for host in hosts:
            code += ('s=socket.create_connection((p.hostname,p.port),timeout=2); '
                     's.sendall(b"CONNECT ' + host + ':443 HTTP/1.1\\r\\n'
                     'X-Fixture: SENTINEL\\r\\n\\r\\n"); '
                     'assert s.recv(4096).startswith(b"HTTP/1.1 502"); s.close(); ')
        return code

    both = contacts("gateway.example.test", "other.example.test")
    human = run(both).stdout
    assert "gateway.example.test · 443 · 1 · gateway" in human
    assert "other.example.test · 443 · 1 · other" in human
    assert human.endswith("PASS\n") and audit.OTHER_NOTE in human
    unexpected = run(both, "--expect-host", "allowed.example.test", expected=2).stdout
    assert "unexpected: other.example.test" in unexpected
    assert unexpected.endswith("ATTENTION: unexpected hosts\n")
    missing = run(contacts("other.example.test"), expected=2).stdout
    assert missing.endswith("ATTENTION: gateway host not contacted\n")
    missing_both = run(contacts("other.example.test"), "--expect-host", "allowed.example.test",
                       "--json", expected=2)
    assert json.loads(missing_both.stdout)["verdict"] == "ATTENTION: gateway host not contacted"
    data = json.loads(run(both, "--json").stdout)
    assert data["verdict"] == "PASS" and data["scope"] == audit.SCOPE
    assert data["gateway_host"] == "gateway.example.test" and data["duration_ms"] >= 0
    assert {r["host"]: r["class"] for r in data["hosts"]} == {
        "gateway.example.test": "gateway", "other.example.test": "other"}
    assert all(r["count"] == 1 and 0 <= r["first_seen_ms"] <= data["duration_ms"] for r in data["hosts"])
    repeated = json.loads(run(contacts("gateway.example.test", "gateway.example.test"), "--json").stdout)
    assert repeated["hosts"][0]["count"] == 2
    run(both, "--expect-host", "allowed.example.test", "--expect-host", "OTHER.EXAMPLE.TEST.")

    # urllib honors inherited proxy exclusions: this request must reach the
    # proxy and be inventoried even though its offline upstream is unreachable.
    proxy_aware = contacts("gateway.example.test") + 'exec(' + repr('''
import urllib.request, urllib.error
try:
    urllib.request.urlopen("http://other.example.test/", timeout=2)
except urllib.error.URLError:
    pass
''') + ')'
    for name in ("NO_PROXY", "no_proxy"):
        for value in ("other.example.test", "other.example.test,SENTINEL"):
            environment[name] = value
            for json_mode in (False, True):
                checked = run(proxy_aware, "--expect-host", "none.example.test",
                              *(["--json"] if json_mode else []), expected=2)
                # The requested hostname necessarily appears; the private
                # exclusion-list suffix must not. Do not print env values.
                if json_mode:
                    data = json.loads(checked.stdout)
                    assert "SENTINEL" not in json.dumps({k: v for k, v in data.items() if k != "command"}) + checked.stderr
                    assert data["no_proxy_was_set"] is True
                    assert data["verdict"] == "ATTENTION: unexpected hosts"
                    assert {r["host"] for r in data["hosts"]} == {"gateway.example.test", "other.example.test"}
                else:
                    assert "SENTINEL" not in checked.stdout.replace(command(proxy_aware), "") + checked.stderr
                    assert checked.stdout.count(audit.NO_PROXY_NOTICE) == 1
                    assert "other.example.test · 80 · 1 · other" in checked.stdout
                    assert checked.stdout.endswith("ATTENTION: unexpected hosts\n")
            del environment[name]

    for suffix, status in (("import sys; sys.exit(7)", "client exited 7"),
                           ("import time; time.sleep(30)", "client timed out after 0.7 s")):
        for json_mode in (False, True):
            checked = run(both + suffix, "--timeout", "0.7",
                          *(["--json"] if json_mode else []), expected=1)
            if json_mode:
                data = json.loads(checked.stdout)
                assert data["client_status"] == status
                assert {r["host"] for r in data["hosts"]} == {"gateway.example.test", "other.example.test"}
            else:
                assert status in checked.stdout and "other.example.test · 443 · 1 · other" in checked.stdout

    # Socket-level malformed input must be bounded and must not poison later
    # valid requests. Invalid targets never enter the inventory.
    for raw in (b"GET http://other.example.test/" + b"SENTINEL" * 9000 + b" HTTP/1.1\r\n\r\n",
                b"CONNECT other.example.test:443 HTTP/1.1\n\n",
                b"CONNECT :443 HTTP/1.1\r\n\r\n"):
        hostile = prefix + 'exec(' + repr('''
with socket.create_connection((p.hostname, p.port), timeout=2) as s:
    try:
        s.sendall(%r)
        assert s.recv(4096) == b""
    except (BrokenPipeError, ConnectionResetError):
        pass
''' % raw) + '); ' + contacts("gateway.example.test")
        data = json.loads(run(hostile, "--json").stdout)
        assert [(r["host"], r["count"]) for r in data["hosts"]] == [("gateway.example.test", 1)]

    idle = contacts("gateway.example.test") + (
        's=socket.create_connection((p.hostname,p.port),timeout=2); '
        's.sendall(b"CONNECT "); import time; time.sleep(30)')
    data = json.loads(run(idle, "--timeout", "0.7", "--json", expected=1).stdout)
    assert data["client_status"] == "client timed out after 0.7 s"
    assert [(r["host"], r["count"]) for r in data["hosts"]] == [("gateway.example.test", 1)]

    concurrent = prefix + 'exec(' + repr('''
import threading
barrier = threading.Barrier(2, timeout=2)
completed = []
def request(host):
    with socket.create_connection((p.hostname, p.port), timeout=2) as s:
        barrier.wait()
        s.sendall(("CONNECT " + host + ":443 HTTP/1.1\\r\\n\\r\\n").encode())
        assert s.recv(4096).startswith(b"HTTP/1.1 502")
        completed.append(host)
workers = [threading.Thread(target=request, args=(host,), daemon=True)
           for host in ("gateway.example.test", "other.example.test")]
for worker in workers:
    worker.start()
for worker in workers:
    worker.join(timeout=3)
assert len(completed) == 2 and not any(worker.is_alive() for worker in workers)
''') + ')'
    data = json.loads(run(concurrent, "--json").stdout)
    assert {(r["host"], r["count"]) for r in data["hosts"]} == {
        ("gateway.example.test", 1), ("other.example.test", 1)}
    (scratch / "customer.env").write_text('GATEWAY_BASE_URL="http://gateway.example.test"\nSENTINEL_ENV=visible\n')
    run(both, "--env", str(scratch / "customer.env"), gateway=False)
    run(both, gateway=False)  # default customer.env
    (scratch / "customer.env").write_text('GATEWAY_BASE_URL=http://wrong.example.test\n')
    run(both, "--env", str(scratch / "customer.env"))  # explicit URL wins
    (scratch / "customer.env").unlink()
    run(both, gateway=False, expected=1)
    run('import sys; sys.exit(7)', expected=1)
    for invalid in ("0", "-1", "nan", "inf", "SENTINEL"):
        run("pass", "--timeout", invalid, expected=1)
    run("pass", "--gateway-url", "http://SENTINEL@localhost", expected=1)
    run("pass", "--expect-host", "http://SENTINEL", expected=1)
    missing_command = subprocess.run([cli, "audit-egress", "--gateway-url", "http://localhost",
                                      "--command", "lucairn_synthetic_missing_command", "--timeout", "1"],
                                     env=environment, capture_output=True, text=True, timeout=3)
    assert missing_command.returncode == 1 and "client exited 127" in missing_command.stderr

    # Lifecycle: a TERM-resistant child, including when its shell leader has
    # already exited. Record only synthetic PID/proxy address for assertions.
    def assert_dead(pid):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            # Linux may retain a killed orphan as a zombie until init reaps it.
            proc_stat = Path('/proc/{}/stat'.format(pid))
            if proc_stat.exists() and proc_stat.read_text().split()[2] == 'Z':
                return
            time.sleep(0.02)
        raise AssertionError("client descendant still running")

    for mode in ("timeout", "interrupt", "leader-exit"):
        state = scratch / (mode + ".json")
        child = command('import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)')
        code = ('import os,json,subprocess,time; '
                'p=subprocess.Popen(' + repr(["/bin/sh", "-c", "exec " + child]) + '); '
                'open(' + repr(str(state)) + ',"w").write(json.dumps([p.pid,os.environ["HTTPS_PROXY"]])); '
                + ('' if mode == "leader-exit" else 'time.sleep(30)'))
        args = [cli, "audit-egress", "--gateway-url", "http://localhost",
                "--timeout", "0.7", "--command", command(code)]
        started = time.monotonic()
        process = subprocess.Popen(args, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            if mode == "interrupt":
                wait_until = time.monotonic() + 2
                while not state.exists() and time.monotonic() < wait_until:
                    time.sleep(0.01)
                process.send_signal(signal.SIGTERM)
            out, err = process.communicate(timeout=4)
            assert process.returncode == (2 if mode == "leader-exit" else 1), (out, err)
            assert time.monotonic() - started < 3
            pid, address = json.loads(state.read_text())
            assert_dead(pid)
            port = int(address.rsplit(":", 1)[1])
            with socket.socket() as check:
                check.settimeout(0.2)
                assert check.connect_ex(("127.0.0.1", port)) != 0
            assert not list(scratch.glob("lucairn-audit-egress-*"))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=2)
            if state.exists():
                try:
                    os.kill(json.loads(state.read_text())[0], signal.SIGKILL)
                except ProcessLookupError:
                    pass

    # Unit-style loopback servers verify actual relaying, including payload
    # bytes arriving in the same write as CONNECT and TCP half-close.
    failures = []
    def server_job(listener, callback):
        try:
            callback(listener)
        except Exception as exc:
            failures.append(exc)
        finally:
            listener.close()

    def listener():
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        sock.listen(5)
        sock.settimeout(3)
        return sock

    # A real plain-HTTP target sends the formerly crashing status line.
    upstream = listener()
    malformed_port = upstream.getsockname()[1]
    def malformed_reply(sock):
        connection, _ = sock.accept()
        with connection:
            connection.settimeout(2)
            with connection.makefile("rb") as stream:
                assert stream.readline().startswith(b"GET http://127.0.0.1:")
                assert stream.readline() == b"\r\n"
            connection.sendall(b"HTTP/1.1\r\n\r\n")
    worker = threading.Thread(target=server_job, args=(upstream, malformed_reply), daemon=True)
    worker.start()
    try:
        code = prefix + ('s=socket.create_connection((p.hostname,p.port),timeout=2); '
                         's.sendall(b"GET http://127.0.0.1:%d/ HTTP/1.1\\r\\n\\r\\n"); '
                         'assert s.recv(4096)==b""; s.close(); ' % malformed_port)
        data = json.loads(run(code + contacts("gateway.example.test"), "--json").stdout)
        assert {(r["host"], r["port"], r["count"]) for r in data["hosts"]} == {
            ("127.0.0.1", malformed_port, 1), ("gateway.example.test", 443, 1)}
    finally:
        worker.join(timeout=3)
        upstream.close()
    assert not worker.is_alive() and not failures, failures

    started = time.monotonic()
    proxy = audit.Forwarder(started, started + 5)
    runner = threading.Thread(target=proxy.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
    runner.start()
    try:
        upstream = listener()
        port = upstream.getsockname()[1]
        def echo(sock):
            connection, _ = sock.accept()
            with connection:
                connection.settimeout(2)
                received = b""
                while True:
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    received += chunk
                assert received == b"SENTINEL\x00\xff"
                connection.sendall(received)
        worker = threading.Thread(target=server_job, args=(upstream, echo), daemon=True)
        worker.start()
        with socket.create_connection(proxy.server_address, timeout=2) as client:
            client.sendall(('CONNECT 127.0.0.1:{} HTTP/1.1\r\n\r\n'.format(port)).encode() + b"SENTINEL\x00\xff")
            stream = client.makefile("rb")
            assert stream.readline() == b"HTTP/1.1 200 Connection Established\r\n"
            assert stream.readline() == b"\r\n"
            client.shutdown(socket.SHUT_WR)
            assert stream.read() == b"SENTINEL\x00\xff"
            stream.close()
        worker.join(timeout=3)
        assert not worker.is_alive()

        upstream = listener()
        http_port = upstream.getsockname()[1]
        requests = [
            ('POST http://127.0.0.1:{}/SENTINEL HTTP/1.1\r\nHost: localhost\r\nContent-Length: 8\r\nX-Fixture: SENTINEL\r\n\r\nSENTINEL'.format(http_port)).encode(),
            ('POST http://127.0.0.1:{}/ HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n8\r\nSENTINEL\r\n0\r\n\r\n'.format(http_port)).encode(),
        ]
        response = b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nX-Fixture: SENTINEL\r\n\r\nSENTINEL"
        def http(sock):
            for expected in requests:
                connection, _ = sock.accept()
                with connection:
                    connection.settimeout(2)
                    received = b""
                    while len(received) < len(expected):
                        received += connection.recv(len(expected) - len(received))
                    assert received == expected
                    connection.sendall(response)
        worker = threading.Thread(target=server_job, args=(upstream, http), daemon=True)
        worker.start()
        with socket.create_connection(proxy.server_address, timeout=2) as client:
            for request in requests:
                client.sendall(request)
                received = b""
                while len(received) < len(response):
                    received += client.recv(len(response) - len(received))
                assert received == response
        worker.join(timeout=3)
        assert not worker.is_alive()
        assert proxy.inventory[("127.0.0.1", http_port)]["count"] == 2
        assert "SENTINEL" not in json.dumps(list(proxy.inventory.values()))
        assert not failures, failures
        assert not proxy.failed.is_set()
    finally:
        proxy.stop()
        runner.join(timeout=1)

    # Bind failure is a sanitized operational error, not a traceback/verdict.
    class BrokenProxy:
        def __init__(self, *_):
            raise OSError("SENTINEL")
    original = audit.Forwarder
    audit.Forwarder = BrokenProxy
    try:
        import contextlib
        import io
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            assert audit.main(["--gateway-url", "http://localhost", "--command", command("pass")]) == 1
        assert "SENTINEL" not in captured.getvalue() and "Traceback" not in captured.getvalue()
    finally:
        audit.Forwarder = original

print("PASS: audit-egress inventory, verdicts, env loading, privacy, forwarding and cleanup")
PY
