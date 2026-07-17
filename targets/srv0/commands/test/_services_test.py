#!/usr/bin/env python3
"""Browser-based integration tests for all exposed services.

Usage (via Atlas dispatch):
    ./atlas.sh srv0 test services

Expects SERVICES_DOMAIN and a domains list file as arguments.
"""

import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout

SKIP = {"traefik", "authelia", "mosquitto"}
TIMEOUT_MS = 30_000
LOGIN_TIMEOUT_MS = 600_000


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

    if "502 bad gateway" in body:
        return f"FAIL  {domain:<30}  Bad Gateway"
    if "internal server error" in body:
        return f"FAIL  {domain:<30}  Internal Server Error"
    if "error" in title.lower() or "not found" in title.lower():
        return f"FAIL  {domain:<30}  title: {title}"

    return f"OK    {domain:<30}  {title}"


def column_format(entries: list[tuple[int, str, str]]) -> str:
    """Render a three-column table: status code, domain, message."""
    lines = []
    for code, domain, msg in entries:
        lines.append(f"  {domain:<32} {msg}")
    return "\n".join(lines)


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
        browser = p.chromium.launch(headless=False)
        context = browser.new_context(ignore_https_errors=True)
        page = context.new_page()

        # Step 1-2: navigate to traefik, detect auth redirect
        print(f"Opening https://{traefik}/ ...")
        page.goto(f"https://{traefik}/", wait_until="domcontentloaded")
        page.wait_for_timeout(2000)

        current_url = page.url
        if "authelia" in current_url:
            print("\nRedirected to Authelia.")
            print("Please log in manually in the browser window.")
            print(f"Waiting for redirect back to {traefik} (up to {LOGIN_TIMEOUT_MS // 60_000} min)...\n")
            try:
                page.wait_for_url(f"**/{traefik}**", timeout=LOGIN_TIMEOUT_MS)
            except PlaywrightTimeout:
                print("\nLogin timed out. Exiting.", file=sys.stderr)
                browser.close()
                sys.exit(1)
            print("Authenticated!\n")
        else:
            print("Already authenticated.\n")

        # Step 4: test all domains
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
