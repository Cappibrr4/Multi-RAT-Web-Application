#!/usr/bin/env python3
"""
Pi Installer Web Server
-----------------------
Runs on the Raspberry Pi. Serves the setup-menu web UI and installer scripts
to any device connected via ethernet cable.

Usage:
    sudo python3 server.py

Endpoints:
    GET  /                     -> setup menu UI (web/index.html)
    GET  /install.sh           -> installer script for target machine
    GET  /check.sh             -> dependency checker script
    GET  /payloads/<file>      -> static files (schedulers, dashboard tarball, etc.)
    POST /api/progress         -> receive progress update from install.sh on target
    GET  /api/status           -> return current install progress as JSON
    POST /api/reset            -> clear progress log

No external dependencies — pure Python 3.7+ standard library.
"""

import http.server
import socketserver
import json
import os
import threading
from datetime import datetime

# ── Config ────────────────────────────────────────────────────────────────────
PORT      = 80
BASE_DIR  = os.path.dirname(os.path.abspath(__file__))
WEB_DIR   = os.path.join(BASE_DIR, 'web')
SCRIPTS_DIR = os.path.join(BASE_DIR, 'scripts')
PAYLOADS_DIR = os.path.join(BASE_DIR, 'payloads')

# ── Shared state (protected by lock) ─────────────────────────────────────────
_lock    = threading.Lock()
_progress = []   # list of {time, step, message, status}
_install_running = False

def _add_progress(step, message, status='info'):
    with _lock:
        _progress.append({
            'time':    datetime.now().strftime('%H:%M:%S'),
            'step':    step,
            'message': message,
            'status':  status,   # 'info' | 'ok' | 'error' | 'running'
        })

# ── Request handler ───────────────────────────────────────────────────────────
class Handler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        # Suppress per-request console spam; only log errors
        if args and str(args[1]) not in ('200', '204'):
            super().log_message(fmt, *args)

    # ── routing ──────────────────────────────────────────────────────────────
    def do_GET(self):
        path = self.path.split('?')[0]

        if path in ('/', '/index.html'):
            self._serve_file(os.path.join(WEB_DIR, 'index.html'), 'text/html')
        elif path == '/install.sh':
            self._serve_file(os.path.join(SCRIPTS_DIR, 'install.sh'), 'text/plain')
        elif path == '/check.sh':
            self._serve_file(os.path.join(SCRIPTS_DIR, 'check.sh'), 'text/plain')
        elif path == '/verify.sh':
            self._serve_file(os.path.join(SCRIPTS_DIR, 'verify.sh'), 'text/plain')
        elif path.startswith('/payloads/'):
            fname = path[len('/payloads/'):]
            # safety: resolve and ensure it stays within PAYLOADS_DIR
            fpath = os.path.normpath(os.path.join(PAYLOADS_DIR, fname))
            if not fpath.startswith(os.path.normpath(PAYLOADS_DIR)):
                self._send(403, 'text/plain', b'Forbidden')
                return
            self._serve_file(fpath, 'application/octet-stream')
        elif path == '/api/status':
            self._api_status()
        elif path == '/api/scheduler-list':
            self._api_file_list(os.path.join(PAYLOADS_DIR, 'schedulers'), '.c')
        elif path == '/api/mpquic-scheduler-list':
            self._api_file_list(os.path.join(PAYLOADS_DIR, 'mpquic_schedulers'), '.go')
        else:
            self._send(404, 'text/plain', b'Not found')

    def do_POST(self):
        path = self.path.split('?')[0]

        if path == '/api/progress':
            length = int(self.headers.get('Content-Length', 0))
            body   = self.rfile.read(length)
            try:
                data = json.loads(body)
                _add_progress(
                    data.get('step', ''),
                    data.get('message', ''),
                    data.get('status', 'info'),
                )
                self._send(204, 'text/plain', b'')
            except Exception:
                self._send(400, 'text/plain', b'Bad JSON')

        elif path == '/api/reset':
            with _lock:
                _progress.clear()
            self._send(204, 'text/plain', b'')

        else:
            self._send(404, 'text/plain', b'Not found')

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    # ── helpers ───────────────────────────────────────────────────────────────
    def _api_status(self):
        with _lock:
            data = list(_progress)
        body = json.dumps(data).encode()
        self._send(200, 'application/json', body)

    def _api_file_list(self, directory, ext):
        if not os.path.isdir(directory):
            self._send(200, 'text/plain', b'')
            return
        files = [f for f in os.listdir(directory) if f.endswith(ext)]
        body = '\n'.join(files).encode()
        self._send(200, 'text/plain', body)

    def _serve_file(self, fpath, content_type):
        if not os.path.isfile(fpath):
            self._send(404, 'text/plain', b'File not found')
            return
        with open(fpath, 'rb') as f:
            body = f.read()
        self._send(200, content_type, body)

    def _send(self, code, content_type, body):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self._cors_headers()
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _cors_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == '__main__':
    class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
    server = ThreadedHTTPServer(('0.0.0.0', PORT), Handler)
    print(f'Pi Installer running on port {PORT}')
    print(f'Open http://multirat-pi.local on the target machine')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nStopped.')
