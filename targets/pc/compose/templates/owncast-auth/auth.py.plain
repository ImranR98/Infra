import os
from http.cookies import SimpleCookie
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs


TOKEN = os.environ["OWNCAST_ACCESS_TOKEN"]
COOKIE_NAME = "owncast_token"
COOKIE_MAX_AGE = 60 * 60 * 24 * 365


class AuthHandler(BaseHTTPRequestHandler):
    def _validate(self):
        cookies = SimpleCookie(self.headers.get("Cookie", ""))
        if COOKIE_NAME in cookies and cookies[COOKIE_NAME].value == TOKEN:
            return True
        return False

    def _check_token_param(self):
        forwarded_uri = self.headers.get("X-Forwarded-Uri", "/")
        parsed = urlparse(forwarded_uri)
        params = parse_qs(parsed.query)
        token = params.get("token", [None])[0]
        return token == TOKEN if token else False

    def _redirect_to_clean_url(self):
        forwarded_uri = self.headers.get("X-Forwarded-Uri", "/")
        parsed = urlparse(forwarded_uri)
        proto = self.headers.get("X-Forwarded-Proto", "https")
        host = self.headers.get("X-Forwarded-Host", "localhost")

        self.send_response(302)
        self.send_header(
            "Set-Cookie",
            f"{COOKIE_NAME}={TOKEN}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age={COOKIE_MAX_AGE}",
        )
        self.send_header("Location", f"{proto}://{host}{parsed.path}")
        self.end_headers()

    def allow(self):
        self.send_response(200)
        self.end_headers()

    def deny(self):
        self.send_response(401)
        self.end_headers()

    def do_GET(self):
        if self._validate():
            return self.allow()
        if self._check_token_param():
            return self._redirect_to_clean_url()
        return self.deny()

    do_POST = do_GET
    do_HEAD = do_GET


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 3000))
    HTTPServer(("0.0.0.0", port), AuthHandler).serve_forever()
