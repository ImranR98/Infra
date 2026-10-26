# Falco exception schema (srv0)

The custom rules file is a YAML **list** of rule overrides:

```yaml
- rule: PTRACE attached to process
  exceptions:
    - name: rocket_league_eac_host
      fields: [container.name, proc.name]
      comps: ["=", "="]
      values:
        - [host, RocketLeague_EA]
  override:
    exceptions: append
```

## The list-of-rows rule

`values` is a **list of rows**, and each row must have the same number of items
as `fields`. This is the most common mistake:

```yaml
# WRONG: three scalar values, not one row -> "Fields and values lists must have equal length"
values: [apps, flaresolverr-, chromedriver]

# RIGHT
values:
  - [apps, flaresolverr-, chromedriver]
```

Quote `=` in flow sequences: `comps: ["=", startswith]`. Unquoted `=` is a YAML
value tag and can be misparsed.

## Fields and operators

Common fields:

- `k8s.ns.name`, `k8s.pod.name`, `container.name`,
  `container.image.repository`, `proc.name`, `proc.pname`, `proc.cmdline`,
  `fd.name`, `user.name`

Operators: `=`, `!=`, `in`, `not in`, `startswith`, `endswith`, `contains`, and
their modifier forms. Use `startswith` for pod prefixes; `=` for a stable
process or namespace.

## Override actions

| Need | YAML |
|---|---|
| Add an exception | `override: {exceptions: append}` |
| Disable a rule | `- rule: X` + `enabled: false` (or `enabled: false` + `override: {enabled: replace}`) |
| Change output (redact) | `output: > ...` + `override: {output: replace}` |
| Raise/lower priority | `priority: WARNING` + `override: {priority: replace}` |

Multiple blocks may target the same rule; each `append` adds exceptions. Keep
exception names unique per rule. The `apply-exceptions.py` script validates the
row lengths and skips scopes already covered by an existing exception.

## Scoping rules

- Prefer namespace + pod prefix + process. Add `fd.name` only for file rules
  (`Read sensitive file*`, `Search private keys*`, `Directory traversal*`,
  `Write below*`, symlink/hardlink rules).
- Host events use `container.name=host` + `proc.name`; never a host-wide
  exception.
- Do not use `proc.name=sh` or `proc.name=curl` without a pod/namespace scope.
- Critical rules (`Drop and execute`, `Netcat`, crypto miner, release_agent,
  memfd, kmod) need explicit user consent unless the user pre-authorized the
  exact app/process.

## Rule names with colons

Quote rule names that contain `: `, e.g. `- rule: "Falco internal: metrics
snapshot"` (that rule is Informational and normally not loaded at
`priority: notice`).
