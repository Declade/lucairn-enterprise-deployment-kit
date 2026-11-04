#!/usr/bin/env python3
"""Synthetic stand-in for the gateway's admin API (K-C tests only).

Serves, on 127.0.0.1:<port>, exactly the two read-only routes the ServiceNow
opt-in checks call:
  GET /api/v1/admin/customers/<customer_id>/keys -> {"keys": [{"key_id": ...}]}
  GET /api/v1/admin/servicenow/status            -> the status body
Both answers come from a JSON state file re-read on every request, so a test
can change them between runs. The X-Admin-Key header must equal the content
of --admin-key-file (synthetic). No real key, id or instance is involved.

  python3 servicenow_admin_stub.py --port-file F --state S --admin-key-file K
"""

import argparse
import http.server
import json
from pathlib import Path
import socketserver


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--admin-key-file", required=True)
    args = parser.parse_args()
    admin_key = Path(args.admin_key_file).read_text().strip()
    state_path = Path(args.state)

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def answer(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.headers.get("X-Admin-Key", "") != admin_key:
                return self.answer(401, {"error": "unauthorized"})
            state = json.loads(state_path.read_text())
            parts = self.path.split("/")
            if self.path == "/api/v1/admin/servicenow/status":
                return self.answer(200, state["status"])
            if len(parts) == 7 and parts[1:5] == ["api", "v1", "admin", "customers"] and parts[6] == "keys":
                keys = state["keys"].get(parts[5])
                if keys is None:
                    return self.answer(404, {"error": {"code": "customer_not_found"}})
                return self.answer(200, {"customer_id": parts[5], "keys": [{"key_id": k, "key_prefix": "lcr_live_x"} for k in keys]})
            return self.answer(404, {"error": "not found"})

    with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
        Path(args.port_file).write_text(str(server.server_address[1]))
        server.serve_forever()


if __name__ == "__main__":
    main()
