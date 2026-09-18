#!/usr/bin/env python3
"""In-process connection counter for the preStop POC. Stdlib only."""
from __future__ import annotations

import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOCK = threading.Lock()
ACTIVE = 0
PORT = 8080


def reply(handler: BaseHTTPRequestHandler, status: int, body: str) -> None:
    data = body.encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "text/plain")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self) -> None:  # noqa: N802
        global ACTIVE
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        path = parsed.path

        if path in ("/", "/livez", "/readyz"):
            reply(self, 200, "ok\n")
            return

        if path == "/openConnections":
            with LOCK:
                count = ACTIVE
            reply(self, 200, str(count))
            return

        if path == "/hold":
            seconds = int(query.get("seconds", ["20"])[0])
            with LOCK:
                ACTIVE += 1
            try:
                time.sleep(seconds)
            finally:
                with LOCK:
                    ACTIVE -= 1
            reply(self, 200, "released\n")
            return

        if path == "/drain":
            deadline = time.time() + 50
            while time.time() < deadline:
                with LOCK:
                    count = ACTIVE
                if count == 0:
                    time.sleep(1)
                    with LOCK:
                        if ACTIVE == 0:
                            reply(self, 200, "drained\n")
                            return
                time.sleep(0.5)
            reply(self, 200, "drained-timeout\n")
            return

        if path == "/stopServer":
            reply(self, 200, "stopping\n")
            return

        reply(self, 404, "not found\n")


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()
