#!/usr/bin/env python3
"""Minimal mock AnyConnect server for Helper engine tests.

Replays the exact auth-form XML that ocserv 1.2.4 returns (captured
2026-10-31 via openconnect --dump-http-traffic), issues a fixed test
cookie, and answers CSTP CONNECT with 401. It is NOT a VPN server:
it never establishes a tunnel. That is precisely the point — the
engine test needs auth + cookie capture + Transient classification,
all without a real gateway or a tun device.

Flow (global request sequence, connections may vary):
  POST /     -> username form (body 1)
  POST /auth -> password form (body 2, first /auth only)
  POST /auth -> complete + Set-Cookie: webvpn=MOCK_COOKIE (later /auth)
  CONNECT /CSCOSSLC/tunnel -> 401 (tunnel never comes up)

The engine's cookie capture is proven when the run-once output shows
a later attempt using "credential cookie" and the CookieStore file
contains MOCK_COOKIE.

Request logging records method + path only, never headers (the
CONNECT request carries the cookie).

Usage:
  mock-anyconnect.py <port> <cert.pem> <key.pem> <ca-cert.pem>
    (cert/key are the server identity; ca-cert is only echoed for
    the caller, the client passes it via --cafile)
  The server runs in the foreground; stop it with SIGINT/SIGTERM.
"""

import http.server
import ssl
import sys
import threading

MOCK_COOKIE = "mockcookie123"
MOCK_CONTEXT = "mockctx456"

BODY_USER = """<?xml version="1.0" encoding="UTF-8"?>
<config-auth client="vpn" type="auth-request">
<version who="sg">0.1(1)</version>
<auth id="main">
<message>Please enter your username.</message>
<form method="post" action="/auth">
<input type="text" name="username" label="Username:" />
</form></auth>
</config-auth>
"""

BODY_PASS = """<?xml version="1.0" encoding="UTF-8"?>
<config-auth client="vpn" type="auth-request">
<version who="sg">0.1(1)</version>
<auth id="main">
<message>Please enter your password.</message>
<form method="post" action="/auth">
<input type="password" name="password" label="Password:" />
</form></auth>
</config-auth>
"""

BODY_DONE = """<?xml version="1.0" encoding="UTF-8"?>
<config-auth client="vpn" type="complete">
<version who="sg">0.1(1)</version>
<auth id="success">
<title>SSL VPN Service</title></auth></config-auth>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    auth_count = 0
    lock = threading.Lock()

    def log_message(self, *args):  # keep stdout clean for the test
        sys.stderr.write("MOCK %s %s\n" % (self.command, self.path))

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

    def _send_xml(self, body, cookies):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/xml")
        self.send_header("X-Transcend-Version", "1")
        for cookie in cookies:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self._read_body()
        if self.path == "/":
            self._send_xml(BODY_USER, [
                "webvpncontext=; expires=Thu, 01 Jan 1970 22:00:00 GMT; "
                "path=/; Secure; HttpOnly",
            ])
        elif self.path == "/auth":
            with self.lock:
                Handler.auth_count += 1
                n = Handler.auth_count
            if n == 1:
                self._send_xml(BODY_PASS, [
                    "webvpncontext=%s; Max-Age=120; Secure; HttpOnly"
                    % MOCK_CONTEXT,
                ])
            else:
                self._send_xml(BODY_DONE, [
                    "webvpncontext=%s; Secure; HttpOnly" % MOCK_CONTEXT,
                    "webvpn=%s; Secure; HttpOnly" % MOCK_COOKIE,
                ])
        else:
            self.send_error(404)

    def do_CONNECT(self):
        # Tunnel never comes up: the client classifies this Transient.
        # Close the connection afterwards, as a real gateway does on
        # a failed CONNECT: with HTTP/1.1 keep-alive and no close, a
        # client that waits for EOF after the 401 deadlocks against
        # this handler waiting for its next request (measured
        # 2026-10-31: macOS openconnect 9.21 stuck forever on a
        # keep-alive 401, no exit, no further traffic).
        self.close_connection = True
        data = b"Cookie is not acceptable"
        self.send_response(401)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    port = int(sys.argv[1])
    cert, key = sys.argv[2], sys.argv[3]
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    sys.stderr.write("MOCK listening on 127.0.0.1:%d\n" % port)
    server.serve_forever()


if __name__ == "__main__":
    main()
