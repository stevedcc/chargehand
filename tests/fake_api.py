#!/usr/bin/env python3
"""A fake OpenCode server for the harness tests.

Serves <dir>/fixtures/<METHOD><path>.json (query strings ignored). A numbered series
<METHOD><path>.1.json, .2.json, ... is served one file per request, the last repeating.
Every request is appended to <dir>/requests.jsonl as {method, path, query, auth, body}.
Requests without HTTP Basic "opencode:$FAKE_API_PASSWORD" get 401; unknown paths get 404.
If <dir>/delay holds a number of seconds, every answer waits that long first.
Writes the port it listens on to <dir>/port.  Usage: fake_api.py <dir>
"""
import base64, json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ROOT = sys.argv[1]
EXPECTED = "Basic " + base64.b64encode(
    ("opencode:" + os.environ.get("FAKE_API_PASSWORD", "test-password")).encode()).decode()
counters = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def handle_any(self, method):
        parts = urlsplit(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        auth = self.headers.get("Authorization", "")
        with open(os.path.join(ROOT, "requests.jsonl"), "a") as log:
            log.write(json.dumps({"method": method, "path": parts.path, "query": parts.query,
                                  "auth": auth, "body": body}) + "\n")
        if os.path.exists(os.path.join(ROOT, "delay")):
            time.sleep(float(open(os.path.join(ROOT, "delay")).read().strip() or 0))
        if auth != EXPECTED:
            return self.reply(401, {"error": "unauthorized"})
        base = os.path.join(ROOT, "fixtures", method + parts.path)
        series, n = [], 1
        while os.path.exists(f"{base}.{n}.json"):
            series.append(f"{base}.{n}.json")
            n += 1
        if series:
            i = counters.get(base, 0)
            counters[base] = i + 1
            path = series[min(i, len(series) - 1)]
        elif os.path.exists(base + ".json"):
            path = base + ".json"
        else:
            return self.reply(404, {"error": "no fixture", "path": parts.path})
        with open(path) as f:
            self.reply(200, json.load(f))

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(ROOT, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
