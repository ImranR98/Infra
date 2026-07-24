#!/usr/bin/env python3
"""Browser-based integration tests for all exposed services.

Usage (via Infra dispatch):
    ./infra.sh srv0 test services

Expects SERVICES_DOMAIN and a domains list file as arguments.
Reads COOKIES_FILE env var for persistent auth storage.
"""

import json
import os
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout, Error as PlaywrightError

SKIP = {"traefik", "authelia", "mosquitto"}
TIMEOUT_MS = 30_000
LOGIN_TIMEOUT_MS = 600_000
COOKIES_FILE = os.environ.get("COOKIES_FILE", "")


def load_domains(path: str) -> list[str]:
    with open(path) as f:
        return [
            line.strip()
            for line in f
            if line.strip() and line.strip().split(".", 1)[0] not in SKIP
        ]


def check_page(page, domain: str) -> str:
    url = f"https://{domain}/"
    try:
        response = page.goto(url, wait_until="domcontentloaded", timeout=TIMEOUT_MS)
    except PlaywrightTimeout:
        return f"FAIL  {domain:<30}  timeout ({TIMEOUT_MS // 1000}s)"

    status = response.status if response else 0

    if status >= 500:
        return f"FAIL  {domain:<30}  HTTP {status}"
    if status >= 400:
        return f"FAIL  {domain:<30}  HTTP {status}"

    title = page.title().strip()
    body = page.content().lower() if status < 400 else ""

    content_type = response.headers.get("content-type", "") if response else ""
    if content_type.startswith("text/plain"):
        return f"FAIL  {domain:<30}  text/plain: {body[:80]}"

    if "502 bad gateway" in body:
        return f"FAIL  {domain:<30}  Bad Gateway"
    if "internal server error" in body:
        return f"FAIL  {domain:<30}  Internal Server Error"
    if "error" in title.lower() or "not found" in title.lower():
        return f"FAIL  {domain:<30}  title: {title}"

    return f"OK    {domain:<30}  {title}"


def save_cookies(context, path: str) -> None:
    if path:
        try:
            cookies = context.storage_state()
            with open(path, "w") as f:
                json.dump(cookies, f)
        except Exception:
            pass


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <SERVICES_DOMAIN> <domains-file>", file=sys.stderr)
        sys.exit(1)

    services_domain = sys.argv[1]
    domains_file = sys.argv[2]

    domains = load_domains(domains_file)
    if not domains:
        print("No domains to test.", file=sys.stderr)
        sys.exit(1)

    traefik = f"traefik.{services_domain}"

    with sync_playwright() as p:
        storage_state = COOKIES_FILE if COOKIES_FILE and os.path.exists(COOKIES_FILE) else None

        browser = p.chromium.launch(headless=False)
        context = browser.new_context(ignore_https_errors=True, storage_state=storage_state)
        page = context.new_page()

        needs_auth = False
        print(f"Opening https://{traefik}/ ...")
        page.goto(f"https://{traefik}/", wait_until="commit")
        page.wait_for_timeout(500)

        try:
            page.wait_for_url(f"**/auth.**", timeout=8000)
            needs_auth = True
        except PlaywrightTimeout:
            print("Using saved session.\n")

        if needs_auth:
            print("\nRedirected to Authelia.")
            print("Please log in manually in the browser window.")
            print(f"Waiting for redirect back to {traefik} (up to {LOGIN_TIMEOUT_MS // 60_000} min)...\n")
            try:
                page.wait_for_url(f"**/{traefik}**", timeout=LOGIN_TIMEOUT_MS)
            except (PlaywrightTimeout, PlaywrightError):
                print("\nLogin did not complete. Exiting.", file=sys.stderr)
                browser.close()
                sys.exit(1)
            print("Authenticated!\n")
            save_cookies(context, COOKIES_FILE)

        results: list[str] = []
        ok_count = 0
        fail_count = 0

        total = len(domains)
        for i, domain in enumerate(domains, 1):
            print(f"[{i:2d}/{total}] {domain}", end="\r", flush=True)
            result = check_page(page, domain)
            results.append(result)
            if result.startswith("OK"):
                ok_count += 1
            else:
                fail_count += 1
            print(result)
            page.wait_for_timeout(5000)

        save_cookies(context, COOKIES_FILE)

        print(f"\n{'=' * 60}")
        print(f"Results: {ok_count} OK, {fail_count} FAIL out of {total}")
        print(f"{'=' * 60}")

        print("\nBrowser stays open for manual inspection. Close it when done.")
        try:
            input("Press Enter to close the browser and exit...")
        except (EOFError, KeyboardInterrupt):
            pass

        browser.close()


if __name__ == "__main__":
    main()
