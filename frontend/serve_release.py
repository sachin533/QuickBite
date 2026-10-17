#!/usr/bin/env python3
"""Serve the Flutter **release** web build on a plain static HTTP server.

Why this exists
---------------
`flutter run -d web-server` serves the app in *debug* mode. The debug bundle
ships an unminified 17 MB ``dart_sdk.js`` plus a hot-reload VM bridge, so the
browser spends seconds parsing JavaScript before the first pixel of the login
screen appears. ``flutter build web --release`` produces a minified ~2.8 MB
bundle instead, and this server hands it out as static files.

It also adds the three things a plain ``python -m http.server`` is missing for a
Flutter single-page app:

* an ``index.html`` fallback for extension-less paths, so refreshing on
  ``/menu`` or ``/history`` does not 404,
* an explicit ``application/wasm`` MIME type for the CanvasKit renderer, and
* a reverse proxy for ``/api/*`` and ``/health/*`` to the FastAPI process on
  :8000, so the browser talks to a single origin. That is what lets one release
  build work on ``localhost`` and behind a tunnel (ngrok gives you only one
  public domain on the free plan), with no CORS preflight in between.

Usage
-----
    python serve_release.py                 # http://127.0.0.1:3000
    python serve_release.py --port 8080
    python serve_release.py --host 0.0.0.0  # reachable from the LAN
    python serve_release.py --verbose       # log every request
"""

from __future__ import annotations

import argparse
import functools
import http.client
import mimetypes
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

# Python's mimetypes db does not always know .wasm on Windows.
mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/javascript", ".js")

BUILD_DIR = Path(__file__).resolve().parent / "build" / "web"

# The FastAPI process. Requests under these prefixes are forwarded to it so the
# browser talks to exactly one origin. That is what lets a single release build
# work unchanged on localhost and behind a tunnel (ngrok exposes only one
# public domain on the free plan, so the API cannot get its own URL) and it
# removes CORS from the browser's path entirely.
API_HOST, API_PORT = "127.0.0.1", 8000
API_PREFIXES = ("/api/", "/health/")

_HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}

VERBOSE = False


class FlutterAppHandler(SimpleHTTPRequestHandler):
    """Static file handler with an SPA fallback + an API reverse proxy."""

    # -- API proxy ---------------------------------------------------------

    def _forward_api(self, method: str) -> bool:
        """Forward this request to the FastAPI process. False if not ours."""
        parsed = urlparse(self.path)
        if not parsed.path.startswith(API_PREFIXES):
            return False

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        target = parsed.path + (f"?{parsed.query}" if parsed.query else "")

        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in _HOP_BY_HOP
        }
        # Keep the browser's original Host so the API sees the real origin.
        if self.headers.get("Host"):
            headers["Host"] = self.headers["Host"]

        try:
            conn = http.client.HTTPConnection(API_HOST, API_PORT, timeout=30)
            conn.request(method, target, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            upstream = resp.getheaders()
            status = resp.status
            conn.close()
        except OSError as exc:
            self.send_error(502, f"API unreachable at {API_HOST}:{API_PORT}: {exc}")
            return True

        self.send_response(status, None)
        for key, value in upstream:
            if key.lower() in {"content-length", "connection", "keep-alive"}:
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if method != "HEAD" and data:
            self.wfile.write(data)
        return True

    def do_GET(self) -> None:
        if not self._forward_api("GET"):
            super().do_GET()

    def do_HEAD(self) -> None:
        if not self._forward_api("HEAD"):
            super().do_HEAD()

    def do_POST(self) -> None:
        self._forward_api("POST")

    def do_PUT(self) -> None:
        self._forward_api("PUT")

    def do_PATCH(self) -> None:
        self._forward_api("PATCH")

    def do_DELETE(self) -> None:
        self._forward_api("DELETE")

    def do_OPTIONS(self) -> None:
        if not self._forward_api("OPTIONS"):
            self.send_error(405)

    # -- static files ------------------------------------------------------

    def end_headers(self) -> None:
        # The build output is immutable per release; the service worker and
        # index.html must always be revalidated.
        if self.path.endswith((".js", ".wasm", ".ttf", ".png", ".jpg", ".json")):
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        else:
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def send_head(self):  # noqa: D102 - mirrors the stdlib signature
        path = self.translate_path(self.path)
        if not Path(path).is_file():
            # Extension-less route (/menu, /history, ...) -> index.html.
            if "." not in Path(self.path).name:
                self.path = "/index.html"
        return super().send_head()

    def log_message(self, fmt: str, *args) -> None:
        if VERBOSE:
            super().log_message(fmt, *args)


def main() -> None:
    global VERBOSE

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3000)
    parser.add_argument("--verbose", action="store_true")
    opts = parser.parse_args()
    VERBOSE = opts.verbose

    if not (BUILD_DIR / "index.html").is_file():
        raise SystemExit(
            f"No release build found at {BUILD_DIR}.\n"
            "Run:  flutter build web --release\n"
            "(add --dart-define=API_BASE_URL=<url> only to override the\n"
            " default: the API is called on this server's own origin)."
        )

    handler = functools.partial(FlutterAppHandler, directory=str(BUILD_DIR))
    with ThreadingHTTPServer((opts.host, opts.port), handler) as httpd:
        print(f"Serving {BUILD_DIR}")
        print(f"  -> http://{opts.host}:{opts.port}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")


if __name__ == "__main__":
    main()
