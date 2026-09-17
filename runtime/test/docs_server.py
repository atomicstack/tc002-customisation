#!/usr/bin/python3
"""browser-test fixture: real reference assets with the existing simulated device api."""
import importlib.util
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mock_device', ROOT / 'panel-v2/mock-device.py')
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)
ASSETS = {'/api/docs': ('index.html', 'text/html'),
          '/api/docs/app.js': ('app.js', 'text/javascript'),
          '/api/docs/style.css': ('style.css', 'text/css'),
          '/api/openapi.json': ('openapi.json', 'application/json'),
          '/api/schema.json': ('schema.json', 'application/schema+json')}

class Handler(mock.Handler):
    def do_GET(self):
        asset = ASSETS.get(self.path)
        if not asset:
            return super().do_GET()
        body = (ROOT / 'runtime/src/net/docs' / asset[0]).read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', asset[1])
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        pass

if __name__ == '__main__':
    with mock.Server(('127.0.0.1', int(sys.argv[1])), Handler) as server:
        server.device = mock.Device(control='c' * 64, admin='a' * 64)
        server.serve_forever()
