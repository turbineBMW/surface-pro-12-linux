"""Serve Camera Check on http://127.0.0.1:8765 (a secure context, so the
camera works) and print measurements the page POSTs to /result (auto mode:
index.html?auto=SECONDS&label=TEXT)."""
import http.server
import json
import os
import sys


class H(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        print(json.dumps(json.loads(body)), flush=True)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


os.chdir(os.path.dirname(os.path.abspath(__file__)))
port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
