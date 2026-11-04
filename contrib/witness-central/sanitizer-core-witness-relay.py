"""Kit 2.0 witness-central: the new sanitizer core's ONE way off the host.

The core runs in the model sidecar's network namespace, whose networks are all
`internal: true` (docker-compose.customer.yml). Under the witness-central
overlay its claims must still reach a CENTRAL witness on another machine. This
relay — a separate container, the only member of the egress network the
overlay adds — accepts TCP on the core's internal witness link and opens a TCP
connection to exactly ONE destination, LUCAIRN_CENTRAL_WITNESS_ADDR. It never
reads or terminates the stream: the core's mTLS session (client leaf from
LUCAIRN_WITNESS_CLIENT_CERT_DIR, server name pinned to dsa-veil-witness) runs
end to end through it, so the relay holds no key and sees ciphertext only.

Environment:
  RELAY_LISTEN_HOST  the relay's alias on the core's witness link; resolved at
                     start and bound to that ONE address (not 0.0.0.0, so the
                     egress network cannot reach the listener). It must be an
                     alias ONLY that internal network carries, never the
                     service name: Docker's resolver answers a service name
                     from the non-internal (egress) network first.
  RELAY_LISTEN_PORT  default 50057
  RELAY_UPSTREAM     host:port or [v6]:port of the central witness claim port
  RELAY_MAX_CONNS    default 64 (further connections are closed at once)

Stdlib only; run as `python3 -I`. Logs carry no payload byte.
"""

import asyncio
import os
import socket
import sys


def split_hostport(v):
    v = v.strip()
    if v.startswith("["):
        host, _, rest = v[1:].partition("]")
        port = rest[1:] if rest.startswith(":") else ""
    else:
        host, _, port = v.rpartition(":")
    if not host or not port.isdigit() or not 0 < int(port) < 65536:
        raise SystemExit("relay: RELAY_UPSTREAM must be host:port (got an unusable value)")
    return host, int(port)


async def pipe(reader, writer):
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionError, OSError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def main():
    listen_host = os.environ.get("RELAY_LISTEN_HOST", "").strip()
    if not listen_host:
        raise SystemExit("relay: RELAY_LISTEN_HOST is required")
    listen_port = int(os.environ.get("RELAY_LISTEN_PORT", "50057"))
    up_host, up_port = split_hostport(os.environ.get("RELAY_UPSTREAM", ""))
    slots = asyncio.Semaphore(int(os.environ.get("RELAY_MAX_CONNS", "64")))
    bind = socket.gethostbyname(listen_host)

    async def handle(cr, cw):
        if slots.locked():
            cw.close()
            return
        async with slots:
            try:
                ur, uw = await asyncio.wait_for(asyncio.open_connection(up_host, up_port), 15)
            except (OSError, asyncio.TimeoutError) as e:
                print("relay: upstream connect failed (%s)" % e.__class__.__name__, file=sys.stderr, flush=True)
                cw.close()
                return
            await asyncio.gather(pipe(cr, uw), pipe(ur, cw))

    server = await asyncio.start_server(handle, bind, listen_port)
    print("relay: %s:%d -> %s:%d (TCP only; the core's mTLS runs end to end)"
          % (bind, listen_port, up_host, up_port), file=sys.stderr, flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
