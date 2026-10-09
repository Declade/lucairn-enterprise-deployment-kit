#!/usr/bin/env python3
"""Inventory proxy request targets; never log traffic or terminate TLS.

Headers and plaintext bodies exist only in transient forwarding buffers. The
inventory retains only host, port, count and time; import has no side effects.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import math
import os
import re
import select
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit


SCOPE = "client process egress via local forwarding proxy; encrypted content not inspected"
OTHER_NOTE = (
    "Hosts marked other were contacted by the client for reasons this audit cannot "
    "see (for example account, update or telemetry traffic). Conversation routing "
    "is proven only by the gateway row and your certificates."
)
LIMIT = 65536


class AuditError(Exception):
    """A fixed, non-sensitive error suitable for displaying to the customer."""


def host_name(value):
    value = value.rstrip(".").lower()
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        if not value or len(value) > 253 or any(
            not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
            for label in value.split(".")
        ):
            raise ValueError("invalid host") from None
        return value


def endpoint(value, connect=False):
    # Reject userinfo and control characters before urlsplit can normalize them.
    if any(ord(char) <= 32 or ord(char) >= 127 for char in value):
        raise ValueError("invalid target")
    parsed = urlsplit("//" + value if connect else value)
    if (parsed.username is not None or parsed.password is not None
            or parsed.fragment or not parsed.hostname):
        raise ValueError("invalid target")
    if connect:
        if parsed.path or parsed.query or parsed.port is None:
            raise ValueError("invalid target")
    elif parsed.scheme not in ("http", "https"):
        raise ValueError("invalid target")
    port = parsed.port if parsed.port is not None else (443 if parsed.scheme == "https" else 80)
    if not 1 <= port <= 65535:
        raise ValueError("invalid port")
    return host_name(parsed.hostname), port


def line(stream):
    data = stream.readline(LIMIT + 1)
    if not data or len(data) > LIMIT or not data.endswith(b"\r\n"):
        raise ValueError("invalid HTTP framing")
    return data


def head(stream):
    """Read bounded protocol framing, without retaining it in the inventory."""
    raw = bytearray()
    fields = {}
    while True:
        part = line(stream)
        raw.extend(part)
        if len(raw) > LIMIT:
            raise ValueError("headers too large")
        if part == b"\r\n":
            return bytes(raw), fields
        key, separator, value = part.partition(b":")
        if not separator or part[:1] in (b" ", b"\t"):
            raise ValueError("invalid headers")
        key = key.lower()
        # Only fields needed to delimit the unchanged byte stream are parsed.
        if key in (b"content-length", b"transfer-encoding", b"connection", b"expect"):
            if key in fields:
                raise ValueError("ambiguous framing")
            fields[key] = value.strip().lower()


def copy_bytes(stream, destination, length):
    while length:
        chunk = stream.read(min(length, LIMIT))
        if not chunk:
            raise ValueError("incomplete body")
        destination.sendall(chunk)
        length -= len(chunk)


def body(stream, destination, fields, response=False):
    """Forward HTTP framing and body bytes verbatim; return whether delimited."""
    transfer = fields.get(b"transfer-encoding")
    length = fields.get(b"content-length")
    if transfer and length:
        raise ValueError("ambiguous framing")
    if transfer:
        if transfer.split(b",")[-1].strip() != b"chunked":
            raise ValueError("unsupported framing")
        while True:
            size_line = line(stream)
            size = int(size_line.split(b";", 1)[0].strip(), 16)
            if size < 0:
                raise ValueError("invalid chunk")
            destination.sendall(size_line)
            if size == 0:
                trailers, _ = head(stream)
                destination.sendall(trailers)
                return True
            copy_bytes(stream, destination, size)
            ending = line(stream)
            if ending != b"\r\n":
                raise ValueError("invalid chunk ending")
            destination.sendall(ending)
    if length is not None:
        if not length.isdigit():
            raise ValueError("invalid length")
        copy_bytes(stream, destination, int(length))
        return True
    if response:
        while True:
            chunk = stream.read(LIMIT)
            if not chunk:
                return False
            destination.sendall(chunk)
    return True


def tunnel(left, right, stopped):
    readers = [left, right]
    while readers and not stopped.is_set():
        ready, _, _ = select.select(readers, [], [], 0.1)
        for source in ready:
            destination = right if source is left else left
            chunk = source.recv(LIMIT)
            if chunk:
                destination.sendall(chunk)
            else:
                readers.remove(source)
                destination.shutdown(socket.SHUT_WR)


class Forwarder(socketserver.ThreadingTCPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = False

    def __init__(self, started, deadline):
        self.started = started
        self.deadline = deadline
        self.stopped = threading.Event()
        self.failed = threading.Event()
        self.lock = threading.Lock()
        self.inventory = {}
        self.connections = set()
        super().__init__(("127.0.0.1", 0), Handler)

    def track(self, connection):
        with self.lock:
            if self.stopped.is_set():
                connection.close()
                raise OSError("proxy stopped")
            self.connections.add(connection)
        connection.settimeout(max(0.01, self.deadline - time.monotonic()))
        return connection

    def forget(self, connection):
        with self.lock:
            self.connections.discard(connection)
        connection.close()

    def record(self, host, port):
        with self.lock:
            if self.stopped.is_set():
                return
            row = self.inventory.setdefault((host, port), {
                "host": host, "port": port, "count": 0,
                "first_seen_ms": int((time.monotonic() - self.started) * 1000),
            })
            row["count"] += 1

    def handle_error(self, request, client_address):
        # socketserver's default prints a traceback; never expose raw inputs.
        self.failed.set()

    def stop(self):
        with self.lock:
            self.stopped.set()
            connections = list(self.connections)
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        self.shutdown()
        self.server_close()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        upstream = None
        try:
            self.server.track(self.request)
            # Unbuffered input leaves any bytes following CONNECT available to
            # the tunnel, including a TLS handshake sent in the same packet.
            with self.request.makefile("rb", buffering=0) as client:
                while not self.server.stopped.is_set():
                    request_line = client.readline(LIMIT + 1)
                    if not request_line:
                        return
                    if len(request_line) > LIMIT or not request_line.endswith(b"\r\n"):
                        raise ValueError("invalid request")
                    method, target, version = request_line.decode("ascii").strip().split(" ")
                    if version not in ("HTTP/1.0", "HTTP/1.1"):
                        raise ValueError("invalid version")
                    host, port = endpoint(target, connect=method == "CONNECT")
                    if method != "CONNECT" and not target.startswith("http://"):
                        raise ValueError("absolute HTTP URL required")
                    self.server.record(host, port)
                    headers, fields = head(client)
                    try:
                        upstream = self.server.track(socket.create_connection(
                            (host, port), timeout=min(5, max(0.01, self.server.deadline - time.monotonic()))
                        ))
                    except OSError:
                        self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                        return
                    if method == "CONNECT":
                        self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                        tunnel(self.request, upstream, self.server.stopped)
                        return
                    # Preserve even the absolute-form request line verbatim.
                    upstream.sendall(request_line + headers)
                    with upstream.makefile("rb", buffering=0) as remote:
                        pending_body = True
                        if fields.get(b"expect") != b"100-continue":
                            body(client, upstream, fields)
                            pending_body = False
                        while True:
                            response_line = line(remote)
                            status = int(response_line.split(b" ")[1])
                            response_headers, response_fields = head(remote)
                            self.request.sendall(response_line + response_headers)
                            if status == 100 and pending_body:
                                body(client, upstream, fields)
                                pending_body = False
                            if status == 101:
                                tunnel(self.request, upstream, self.server.stopped)
                                return
                            if status >= 200:
                                break
                        delimited = True
                        if method != "HEAD" and status not in (204, 304):
                            delimited = body(remote, self.request, response_fields, response=True)
                    self.server.forget(upstream)
                    upstream = None
                    if (pending_body or not delimited or version == "HTTP/1.0"
                            or b"close" in fields.get(b"connection", b"")
                            or b"close" in response_fields.get(b"connection", b"")):
                        return
        except (OSError, ValueError, UnicodeError):
            # Bad peer input, unreachable targets and disconnects are not a
            # proxy failure. Do not log exception text (it can contain traffic).
            return
        finally:
            if upstream is not None:
                self.server.forget(upstream)
            self.server.forget(self.request)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise AuditError("invalid arguments (see --help)")


def stop_client(process):
    if process is None:
        return
    # Kill the entire group even if the shell leader already exited.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=0.2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=1)


def run(args):
    started = time.monotonic()
    deadline = started + args.timeout
    proxy = None
    thread = None
    process = None
    try:
        proxy = Forwarder(started, deadline)
        thread = threading.Thread(target=proxy.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        environment = os.environ.copy()
        address = "http://127.0.0.1:{}".format(proxy.server_address[1])
        for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
            environment[name] = address
            environment[name.lower()] = address
        # TemporaryFile is private and unlinked immediately on POSIX. Nothing
        # ever reads it; closing the descriptor discards the client output.
        with tempfile.TemporaryFile(prefix="lucairn-audit-egress-", mode="w+b") as output:
            process = subprocess.Popen(
                args.command, shell=True, executable=environment.get("SHELL") or "/bin/sh",
                env=environment, stdout=output, stderr=output, start_new_session=True,
            )
            try:
                code = process.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                raise AuditError("client timed out") from None
            finally:
                stop_client(process)
                process = None
        if proxy.failed.is_set() or not thread.is_alive():
            raise AuditError("local proxy failed")
        if code in (126, 127):
            raise AuditError("client command not found or not executable")
        if code != 0:
            raise AuditError("client command exited unsuccessfully")
    except (OSError, RuntimeError, subprocess.SubprocessError):
        raise AuditError("could not start or run client/local proxy") from None
    finally:
        try:
            stop_client(process)
        finally:
            if proxy is not None:
                if thread is not None and thread.is_alive():
                    proxy.stop()
                    thread.join(timeout=1)
                else:
                    proxy.server_close()
    if proxy.failed.is_set():
        raise AuditError("local proxy failed")
    hosts = []
    for key in sorted(proxy.inventory):
        row = dict(proxy.inventory[key])
        row["class"] = "gateway" if row["host"] == args.gateway_host else "other"
        hosts.append(row)
    unexpected = sorted({row["host"] for row in hosts
                         if row["class"] == "other" and args.expect_host
                         and row["host"] not in args.expect_host})
    if not any(row["class"] == "gateway" for row in hosts):
        verdict = "ATTENTION: gateway host not contacted"
    elif unexpected:
        verdict = "ATTENTION: unexpected hosts"
    else:
        verdict = "PASS"
    return {
        "command": args.command, "gateway_host": args.gateway_host,
        "hosts": hosts, "unexpected": unexpected, "verdict": verdict,
        "duration_ms": int((time.monotonic() - started) * 1000), "scope": SCOPE,
    }


def main(argv=None):
    def interrupted(signum, frame):
        raise AuditError("audit interrupted")

    handlers = {}
    try:
        if sys.version_info < (3, 8):
            raise AuditError("python3 >= 3.8 is required")
        parser = Parser(description=__doc__)
        parser.add_argument("--gateway-url", required=True)
        parser.add_argument("--command", default='claude -p "Reply with exactly: OK"')
        parser.add_argument("--timeout", type=float, default=120)
        parser.add_argument("--json", action="store_true")
        parser.add_argument("--expect-host", action="append", default=[])
        args = parser.parse_args(argv)
        if not math.isfinite(args.timeout) or args.timeout <= 0:
            raise AuditError("timeout must be a positive finite number")
        if not args.command.strip() or any(ord(c) < 32 or ord(c) == 127 for c in args.command):
            raise AuditError("command must be nonempty and contain no control characters")
        try:
            args.gateway_host, _ = endpoint(args.gateway_url)
            args.expect_host = [host_name(host) for host in args.expect_host]
        except ValueError:
            raise AuditError("invalid gateway URL or expected host") from None
        for signum in (signal.SIGINT, signal.SIGTERM):
            handlers[signum] = signal.signal(signum, interrupted)
        result = run(args)
        if args.json:
            print(json.dumps(result, ensure_ascii=True))
        else:
            print("Egress audit — hosts contacted by `{}` during one synthetic turn, "
                  "as observed by a local forwarding proxy on this machine. "
                  "Encrypted content is not inspected.".format(result["command"]))
            print("\nhost · port · requests · class")
            for row in result["hosts"]:
                print("{host} · {port} · {count} · {class}".format(**row))
            print("\n" + OTHER_NOTE)
            if result["unexpected"]:
                print("\nunexpected: " + ", ".join(result["unexpected"]))
            print("\n" + result["verdict"])
        return 0 if result["verdict"] == "PASS" else 2
    except AuditError as exc:
        print("error: audit-egress: " + str(exc), file=sys.stderr)
        return 1
    except (OSError, RuntimeError, subprocess.SubprocessError):
        print("error: audit-egress: client/proxy operation failed", file=sys.stderr)
        return 1
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    sys.exit(main())
