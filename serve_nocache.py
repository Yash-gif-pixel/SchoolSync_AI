"""Static file server that refuses to be cached.

`python -m http.server` sends only Last-Modified, so browsers are free to
apply heuristic caching — which on a Flutter web build means you rebuild,
reload, and still stare at the previous bundle. Every response here is
no-store, so a plain reload always shows the build that is actually on disk.

    python serve_nocache.py [port] [directory]
"""

import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt: str, *args) -> None:
        pass  # the console is for the build output, not a request log


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    directory = sys.argv[2] if len(sys.argv) > 2 else "."
    handler = partial(NoCacheHandler, directory=directory)
    with ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
