#!/usr/bin/env python3
# ************************************************************************************************
# *** SHARED CODE. The source is shared/collector/serve.py.
# *** Byte-identical copies live in charts/ipsec-nas/files/ and charts/ipsec-nas-option-c-metrics/files/.
# *** Change the shared file first, then run scripts/sync-shared-collector.sh: it copies it to BOTH charts.
# *** tests/test-shared-collector.sh fails when a copy differs.
# ************************************************************************************************
"""Serves the metrics file written by the collector container, and nothing else."""
import http.server
import os

METRICS_FILE = os.environ.get("METRICS_FILE", "/metrics/ipsec_nas.prom")
PORT = int(os.environ.get("METRICS_PORT", "9754"))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            try:
                with open(METRICS_FILE, "rb") as f:
                    self._send(200, f.read(), "text/plain; version=0.0.4; charset=utf-8")
            except OSError as err:
                # 503 makes the scrape fail, which is what should happen while there is no data
                self._send(503, f"metrics file not readable: {err}\n".encode(), "text/plain")
        elif self.path == "/healthz":
            self._send(200, b"ok\n", "text/plain")
        else:
            self._send(404, b"not found\n", "text/plain")

    def _send(self, code, body, content_type):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # one scrape every 30 seconds per node would bury every other line in the pod log
        pass


if __name__ == "__main__":
    print(f"serving {METRICS_FILE} on :{PORT}/metrics", flush=True)
    http.server.ThreadingHTTPServer(("", PORT), Handler).serve_forever()
