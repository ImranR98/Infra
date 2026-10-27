# Test gate

The gate exists to make major updates safe to automate. A suite that only proves
the app starts is not enough for major auto-merge; a suite that proves the
critical behavior and the production image works may be.

## Sufficiency criteria

A major update may auto-merge only when all of these are true:

1. The `test` job runs on every PR and the daily merge helper requires it to be `success` (public repos may also enforce it via branch protection; private repos cannot, so the helper is the gate).
2. Install/build/lint/typecheck pass from the lockfile.
3. Tests exercise the app's primary behavior, not just construction.
4. The production image builds and passes a smoke test.
5. There are no silently skipped tests; missing tools/prerequisites fail.
6. The result is deterministic and hermetic enough for CI.
7. The agent can explain what a major break would look like and which tests
   would catch it.

If any criterion is missing, either add the missing coverage or keep majors
manual. Do not claim a gate you do not have.

## Assess existing tests first

- Run the real test command; record pass/fail/skip counts and duration.
- Read the test files: do they assert behavior or just snapshots/construction?
- Check for conditional skips, missing browsers/tools, network calls, shared
  state, fixed ports, and time-dependent assertions.
- Check whether CI already runs the tests. Tests that only run locally are not a
  gate yet.
- If the suite passes and covers the critical paths, **reuse it**. Add CI and an
  image smoke; do not rewrite it to match a template.
- A `test` script that intentionally exits non-zero is a placeholder, not a
  suite. Replace it.

## App-shape defaults

| Shape | Minimum meaningful gate | Common additions |
|---|---|---|
| Static site | build; HTML/link/asset checks; browser smoke; image serves | Playwright for critical pages |
| SSR/full-stack | unit + route/SSR + migration tests; image health | auth, data isolation, forms |
| HTTP API/service | unit + HTTP tests; health; image smoke | auth, validation, error paths |
| Worker/daemon | unit + fixture-based processing; start/stop; image smoke | queue/retry, file events |
| Batch/media pipeline | fixture inputs/outputs; system-tool versions; CLI smoke | exiftool/ffmpeg edge cases |
| Shell service | shellcheck; config/parser tests; fake external calls; image run | log/stream filters, notifications |
| Multi-package | tests in every package; client build; image smoke | cross-package contracts |
| CLI | unit + CLI integration; `--help`/exit codes; package smoke | fixture files |
| Upstream-binary wrapper | build; binary version/help; config validation | upstream release notes; majors manual |
| Desktop/GUI | core logic/CLI tests; build/package smoke | GUI automation only if feasible |
| Library | unit/type/build tests; package install smoke | API compatibility |

## Hermeticity

- Use temp dirs; isolate state per test.
- Mock external HTTP/notification services; no live network in the gate.
- Use ephemeral ports; never fixed ports that can collide.
- Poll with timeouts instead of arbitrary sleeps.
- Do not require secrets. If a test needs credentials, it is not a default CI
  gate; move it to a separately approved job or use a fake.
- Keep tests deterministic across time zones, locale, and CPU count.
- Avoid snapshot tests as the only protection for a major dependency.

## No-skip policy

A missing browser, media tool, native compiler, or database must fail the job or
be installed, not silently skip the tests that need it.

Common patterns:

- assert required commands exist before running the suite;
- throw from the test helper when a required tool/browser is missing in CI;
- grep the test output for `SKIP` and fail if present;
- log the installed versions of runtime/system tools.

Document any intentionally skipped/platform-specific test, and treat it as a
gate gap if it covers critical behavior.

## Production-image smoke

The test job should build the exact image that publish will push, then:

- run the app with a temporary config/state directory;
- hit a health endpoint or the main page;
- exercise one real request/CLI invocation;
- verify the runtime version and required system tools;
- check production dependencies resolve (`npm ls --omit=dev` or equivalent).

If the app has no health endpoint:

- prefer adding a tiny health endpoint (ask if it changes behavior);
- otherwise check the port/HTTP response or a CLI/process-level signal;
- for a batch/daemon, run a fixture through it and assert the output.

## Native and system tools

- Native modules need their toolchain in CI (python3, make, g++, build-base).
- Media/image tools need their packages installed and versioned in CI.
- Docker-socket/Kubernetes-token features are hard to test in CI; use fakes for
  the parsing/decision logic and document the untested integration.
- If the app needs a different base OS (PPA, veracrypt, vendor packages), do not
  force a Node-slim/Debian base. Keep the OS, pin it by digest, and explain why.

## Upstream-binary wrappers

Some images only download and run a third-party binary. The app has little or no
logic to test. A reasonable gate is:

- deterministic build with pinned upstream version(s),
- binary `--version`/`--help`,
- config file parse/validation,
- a smoke run if the binary can start without side effects,
- upstream release notes read for majors.

This is not enough for automatic majors; leave majors manual unless the wrapper
has real tests and a safe smoke.

## Major auto-merge decision

Enable all update types only when the gate is sufficient **and** branch
protection/auto-merge are configured. Otherwise:

- auto-merge non-major updates only, or
- disable auto-merge for the app and keep the pipeline review-only.

Record the decision in the report with the evidence. A weak gate plus major
auto-merge is a policy violation, not an onboarding shortcut.

## What not to do

- Do not add tests that assert `true`, only snapshot a build, or only check that
  a process exists.
- Do not add a test framework the app cannot run in CI.
- Do not rewrite a passing suite just to standardize it.
- Do not make tests depend on production services, secrets, or the user's data.
- Do not hide failures with retries, broad catches, or skips.
- Do not change production behavior to make a test pass without asking.
- Do not claim coverage from a test that never runs in CI.

## Test plan output

Before implementing a large suite, present:

```text
Existing tests:
Gaps for majors:
Proposed tests (file/level/why):
Production-image smoke:
Prerequisites/tools:
Estimated CI time:
Gate decision (majors auto-merge? yes/no/why):
```
