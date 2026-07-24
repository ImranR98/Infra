# SELinux MCS Troubleshooting: A Deep Dive

This document explains the journey of debugging why persistent volumes on a
K3s node produced SELinux denials after migrating from NFS-backed storage to
Longhorn. It is written for someone with basic Kubernetes knowledge (pods,
PVs, PVCs) and Linux familiarity. Every new concept is explained as it
appears.

---

## 1. The Problem

After migrating 22 persistent volumes from an NFS server to Longhorn (local
block storage), several applications broke with cryptic `Permission denied`
errors — even though Unix file permissions looked correct. The `setroubleshootd`
daemon (SELinux alert processor) pegged a CPU core at 49%, and the audit log
contained over 80,000 denials.

The errors appeared in multiple forms:

- PostgreSQL: `FATAL: could not open file "global/pg_filenode.map": Permission denied`
- Immich server: `ECONNREFUSED` to PostgreSQL (the DB was alive but rejecting connections internally)
- Authelia: `unable to load user information: Stale file handle`
- Home Assistant: continuous `{ lock }` denials on its SQLite WAL file

All of these shared the same root cause: SELinux MCS category isolation.

---

## 2. Core Concepts

### 2.1 What Is SELinux?

SELinux (Security-Enhanced Linux) is a mandatory access control system built
into the Linux kernel. Unlike Unix permissions (which are based on user/group
ownership and checked per-process), SELinux assigns a **security context** to
every process and every file. The kernel enforces rules about which contexts
can access which other contexts — even `root` is not exempt.

A full SELinux context looks like this:

```
system_u:system_r:container_t:s0:c123,c456
```

This breaks down into four parts:

| Part | Example | Meaning |
|------|---------|---------|
| **SELinux user** | `system_u` | SELinux user identity (almost always `system_u` for system processes) |
| **Role** | `system_r` | SELinux role (almost always `system_r` or `object_r` for files) |
| **Type** | `container_t` | The type — this is what access rules are written against. `container_t` is the type for container processes. |
| **Level** | `s0:c123,c456` | The sensitivity level (`s0`) and MCS categories (`c123,c456`) |

### 2.2 MCS Categories

MCS (Multi-Category Security) is an optional SELinux feature that assigns
unique "category" pairs to isolate processes that share the same type. On a
Kubernetes node, every container process has `container_t` as its type — if
type enforcement were the only mechanism, all containers could access each
other's files.

MCS solves this: Kubernetes assigns each pod two random categories (e.g.,
`c123,c456`). Files created by that pod inherit its categories. A different
pod with categories `c789,c012` cannot access those files unless it also has
`c123,c456` in its context.

The key rule is **dominance**: a process with level `s0:c1,c2,c3` dominates
a file with level `s0:c1,c2` (the process has a superset of the file's
categories). A process with `s0:c1` does *not* dominate a file with
`s0:c1,c2` — access is denied.

A process with `s0` (no categories) dominates any file with `s0:cX,cY` (the
empty set is a subset of every set). This is the key insight used in our fix.

### 2.3 How Files Get Their Labels

When a pod creates a file on a persistent volume:
1. The pod's container has an SELinux context assigned by Kubernetes (including MCS categories)
2. The kernel's VFS layer assigns the pod's context to any new files on xattr-supporting filesystems (like ext4)
3. The file's context persists on the volume even after the pod terminates

When a *different* pod later mounts the same PVC:
1. The new pod gets its own (different) MCS categories
2. Existing files on the volume retain their original categories
3. If the categories don't match, SELinux blocks access

### 2.4 `privileged: true` and SELinux

A container with `privileged: true` runs with **all** Linux capabilities,
including those that bypass SELinux enforcement (`CAP_MAC_OVERRIDE`,
`CAP_MAC_ADMIN`). This means:

- The container can read/write any file regardless of its SELinux context
- However, **new files created by the container still get labeled** with the
  container's SELinux context (the kernel doesn't skip labeling for privileged
  processes)
- So a privileged restore pod can read old files with wrong categories, but the
  files it writes still carry its categories — which a non-privileged workload
  pod may not be able to read later

---

## 3. Architecture

```
                    PVC (Longhorn ext4 volume)
                    ┌─────────────────────────────┐
                    │  Files created by Pod A:    │
                    │    s0:c815,c939              │
                    │                             │
                    │  Pod B tries to read:       │
                    │    s0:c237,c927              │
                    │    — different categories —  │
                    │    SELinux: ACCESS DENIED    │
                    └─────────────────────────────┘
         ▲                                     ▲
         │                                     │
    ┌─────────┐                          ┌─────────┐
    │ Pod A   │                          │ Pod B   │
    │ restore │                          │ postgres│
    │ s0:c815 │                          │ s0:c237 │
    │  c939   │                          │  c927   │
    └─────────┘                          └─────────┘
```

Two pods access the same PVC. Pod A (a restore utility) writes files with its
own categories. Pod B (the database workload) mounts the PVC later with
different categories. Even though Unix permissions are correct, SELinux blocks
access because the categories don't match.

---

## 4. The Troubleshooting Journey

### 4.1 Symptom: PostgreSQL "Permission Denied" With Correct Unix Perms

The first sign was Immich's PostgreSQL pod continuously crashing:

```
FATAL: could not open file "global/pg_filenode.map": Permission denied
LOG:  could not open file "postmaster.pid": Permission denied; continuing anyway
```

Checking Unix permissions looked fine — the database directory was owned by
`999:1000` with mode `rwxrws---`, and files had `rw-rw----`. The PostgreSQL
process runs as UID 999, which is the file owner. By Unix rules, access should
be permitted.

#### Diagnosis: Check the Process's SELinux Context

```bash
kubectl exec -n apps deploy/immich-postgresql -- cat /proc/1/attr/current
# → system_u:system_r:container_t:s0:c214,c813
```

The process context has MCS categories `c214,c813`.

#### Diagnosis: Check the File's SELinux Context

```bash
kubectl exec -n apps deploy/immich-postgresql -- \
    sh -c 'ls -laZ /var/lib/postgresql/data/pgdata/global/pg_filenode.map'
# (may need getfattr if ls -Z is not available)
```

**Background: `ls -laZ`.** The `-Z` flag tells `ls` to display the SELinux
context of each file. On distros with SELinux enabled, this is built into GNU
coreutils. On minimal container images (Alpine), `ls` may not support `-Z`.
Use `getfattr -n security.selinux <path>` from the `attr` package as an
alternative.

The file's context was something like `s0:c815,c939` — different categories
from the process. Access denied.

### 4.2 Symptom: Root Can't List the Directory

A deeper clue: even running commands as `root` inside the PostgreSQL container
failed:

```bash
kubectl exec -n apps deploy/immich-postgresql -- id
# → uid=0(root) gid=0(root) groups=0(root),1000

kubectl exec -n apps deploy/immich-postgresql -- ls /var/lib/postgresql/data/
# → Permission denied
```

`root` (UID 0) cannot bypass SELinux without specific capabilities. The
container had `allowPrivilegeEscalation: false`, which means it runs without
`CAP_DAC_OVERRIDE` and `CAP_MAC_OVERRIDE`. Root inside this container is
subject to SELinux enforcement.

### 4.3 The `setroubleshootd` High CPU Symptom

After deploying the migrated volumes, the host's CPU usage spiked:

```bash
ps aux | grep setrouble
# → setroub+  25128 49.3  ...  /usr/sbin/setroubleshootd -f
```

**Background: `setroubleshootd`.** This is a daemon that reads the SELinux
audit log, translates raw denials into human-readable alerts, and (on desktop
systems) displays notifications. It's purely diagnostic — it doesn't enforce
anything. High CPU means it's processing a large backlog of denials.

The denial count confirmed the scale:

```bash
sudo ausearch -m avc --start recent | wc -l
# → 80613
```

#### Diagnosing the Denial Source

To see which files are generating the most denials:

```bash
sudo ausearch -m avc -ts recent 2>/dev/null | \
    grep -oP 'path="/[^"]*"' | \
    sort | uniq -c | sort -rn | head -5
```

**Background: `ausearch`.** This tool queries the Linux audit daemon's logs
for specific event types. `-m avc` filters for SELinux Access Vector Cache
(denial) messages. `-ts recent` uses a 10-minute lookback. Requires `sudo`.

Example output during our migration:
```
23550 path="/config/home-assistant_v2.db-shm"
 2905 path="/var/syncthing/config/index-v2/main.db-shm"
```

This immediately identified the affected PVCs.

#### Finding Which Pod Matches a Set of Categories

The denial's `scontext` field (source context) contains the pod's MCS
categories. To find which running pod has those categories:

```bash
kubectl get pods -A -o json | jq -r \
    '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
while read ns name; do
    ctx=$(kubectl exec -n "$ns" "$name" -- cat /proc/1/attr/current 2>/dev/null)
    echo "$ns/$name $ctx"
done | grep c160,c948
```

This iterates over every pod, reads its SELinux context, and filters for the
target category pair.

### 4.4 Why `chcon -l s0` Doesn't Work Inside a Container

Our first attempt to fix the files after-the-fact was to strip MCS categories
with `chcon`:

```bash
chcon -l s0 /data/pgdata/global/pg_filenode.map   # doesn't work in a container
```

**Background: `chcon`.** This command changes the SELinux context of a file.
`-l s0` sets the level (sensitivity + categories) to just `s0` with no
categories.

This failed because the kernel's MCS policy re-applies the process's own
categories to any file touched by `chcon`. Even with `privileged: true` (which
grants `CAP_MAC_ADMIN`), the MCS policy overrides the explicit level setting.

The only way to create files without categories is to run the *creating process*
itself without categories — at the pod level, not by modifying files afterward.

### 4.5 The Container vs. Pod-Level `seLinuxOptions`

This was the critical discovery. Our first fix added `seLinuxOptions` to the
**container** spec:

```yaml
# Container-level — DOES NOT WORK
containers:
- name: restore
  securityContext:
    privileged: true
    seLinuxOptions:
      level: "s0"
```

Checking the pod's actual context revealed it still had categories:

```bash
cat /proc/1/attr/current
# → system_u:system_r:spc_t:s0:c237,c927   ← still has categories!
```

**Why:** Kubernetes assigns MCS categories at the **pod** level, not the
container level. Setting `seLinuxOptions` on a container only overrides the
type and role for that specific container — the pod-level categories still
apply.

**The fix:** Move `seLinuxOptions` to the pod's `spec.securityContext`:

```yaml
# Pod-level — WORKS
spec:
  securityContext:
    seLinuxOptions:
      level: "s0"
  containers:
  - name: restore
    securityContext:
      privileged: true
```

Result:

```bash
cat /proc/1/attr/current
# → system_u:system_r:spc_t:s0   ← no categories!
```

**Why this works:** With pod-level `level: "s0"`, the kernel assigns the pod
exactly `s0` with no MCS categories. Files created by this pod carry `s0`.
Any other pod with `s0:cX,cY` can access them — because `s0:cX,cY` dominates
`s0` (the process has a superset of the file's categories).

### 4.6 The Nightly Backup Recurrence

After fixing all restored PVCs, the denials came back overnight. The 3 AM
CronJob runs `backup-pvc.sh --all`, which creates a temporary pod that:

1. Mounts each PVC
2. Writes `__backup_timestamp.txt` to the PVC root
3. Runs `tar czf` to create the backup archive
4. Deletes the timestamp file

The `__backup_timestamp.txt` write and the `tar` read both touch the PVC's
file tree. When a backup pod (with MCS categories) touches files alongside
a running workload's SQLite database, the WAL manager creates new `-shm`
shared-memory files — and those new files inherit the **backup pod's**
categories. The workload pod then cannot lock them, generating continuous
`{ lock }` denials.

**The fix:** Apply the same pod-level `seLinuxOptions.level: "s0"` to the
backup pod YAML generator (`pvc_backup_pod_yaml()` in `lib/pvc.sh`), just
as was done for the restore pod.

### 4.7 The io_uring Case (Bonus)

After all PVC-related denials were resolved, a smaller set remained:

```
AVC avc: denied { create } for pid=2570808 comm="MainThread"
  anonclass=[io_uring]
  scontext=system_u:system_r:container_t:s0:c160,c948
  tcontext=system_u:object_r:io_uring_t:s0:c160,c948
  tclass=anon_inode permissive=0
```

**Background: io_uring.** A Linux kernel I/O interface introduced in 5.1 that
allows applications to submit I/O operations asynchronously without system
calls. Python 3.10+ uses it by default in `asyncio` when available.

The denial shows `permissive=0` — this is enforced, not just logged. The fix
required finding which pod's categories (`c160,c948`) matched.

The culprit was `monitoring/logtfy`, a Python-based log monitoring service.
Its `asyncio` event loop defaulted to io_uring, which SELinux on Fedora 44
doesn't allow for containers.

**Fix:** There is no SELinux boolean or capability that grants io_uring to
containers without full `privileged: true` (which bypasses all SELinux
enforcement). Both runtimes *do* fall back to `epoll` — the app continues
working — but they retry `io_uring_setup()` periodically, producing
continuous audit denials and `setroubleshootd` CPU load. The fix is to
tell the I/O library not to bother trying:

| Runtime | Env var | Effect |
|---------|---------|--------|
| Python (asyncio) | `PYTHON_IO_URING=0` | Skips `io_uring_setup()`, uses `epoll` directly |
| Node.js / Deno (libuv) | `UV_USE_IO_URING=0` | Skips `io_uring_setup()`, uses `epoll` directly |

No SELinux policy changes needed, no system-level modifications, no new
packages — just an env var on the affected deployment.

---

## 5. Command Reference

### Process and File Contexts

| Command | Purpose |
|---------|---------|
| `cat /proc/<pid>/attr/current` | Read a process's SELinux context (commonly PID 1 for the container's main process) |
| `ls -laZ <path>` | List files with their SELinux contexts (GNU coreutils, `-Z` flag) |
| `getfattr -n security.selinux <path>` | Read the SELinux xattr from a specific file (requires `attr` package, works on Alpine) |
| `ps auxZ` | List processes with their SELinux contexts |

### Audit and Denial Diagnostics

| Command | Purpose |
|---------|---------|
| `sudo ausearch -m avc -ts recent` | Show recent SELinux denials (10-min window) |
| `sudo ausearch -m avc --start recent \| wc -l` | Count total denials in the audit backlog |
| `journalctl _TRANSPORT=audit --since "5 min ago" --no-pager` | Show recent audit messages from the journal (no sudo if user is in `systemd-journal` group) |
| `... \| grep "avc.*denied" \| grep -oP 'path="/[^"]*"' \| sort \| uniq -c \| sort -rn` | Aggregate denials by file path |
| `... \| grep -oP 'scontext=\S*' \| sort \| uniq -c \| sort -rn` | Aggregate denials by source context (identify which pod) |

### Fixing Files and Processes

| Command | Purpose |
|---------|---------|
| `chcon -l s0 <path>` | Attempt to strip MCS categories (usually blocked by MCS policy inside a container) |
| `setenforce 0` / `setenforce 1` | Temporarily switch to permissive/enforcing mode (requires `CAP_MAC_ADMIN`, won't help with MCS category enforcement) |

### Matching MCS Categories to Pods

```bash
kubectl get pods -A -o json | jq -r \
    '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
while read ns name; do
    ctx=$(kubectl exec -n "$ns" "$name" -- cat /proc/1/attr/current 2>/dev/null)
    echo "$ns/$name $ctx"
done | grep <categories>
```

### Finding the Source of `setroubleshootd` CPU

```bash
ps aux | grep setrouble                    # see the daemon's CPU usage
sudo ausearch -m avc --start recent | wc -l  # see how many denials it's processing
```

---

## 6. Changes Summary

| File | Change | Why |
|------|--------|-----|
| `lib/pvc.sh:pvc_restore_pod_yaml()` | Moved `seLinuxOptions.level: s0` to pod-level `spec.securityContext` | Files extracted by the restore pod carry `s0` (no categories), readable by any workload pod |
| `lib/pvc.sh:pvc_backup_pod_yaml()` | Same pod-level `seLinuxOptions.level: s0` | Prevents 3 AM CronJob from writing category-tainted files to production PVCs |
| `mosquitto/mosquitto.yaml` | Added `fsGroup: 1883` to pod securityContext | Kubelet chowns the Longhorn volume root so mosquitto (UID 1883) can write its data on first start |
| `navidrome/navidrome.yaml` | Added `fsGroup: $MY_UID` to pod securityContext | Same — kubelet chowns the volume root for navidrome |
| `gokapi/gokapi.yaml` | Set explicit `command: [/sbin/tini, --, /app/run.sh]` and added `GOKAPI_DEPLOYMENT_PASSWORD` to VARS | Fresh Longhorn data PVC needed a deployment password for one-time init; the `tini` entrypoint override was needed because the Docker image uses `tini` as ENTRYPOINT without `CMD` |
| `logtfy/logtfy.yaml` | Added `PYTHON_IO_URING: "0"` env var | Prevents Python `asyncio` io_uring SELinux denials |
| `dscpln/dscpln.yaml` | Added `UV_USE_IO_URING: "0"` env var | Prevents Node.js libuv io_uring SELinux denials |
| `lib/env.sh` | Added `ATLAS_ROOT` to `get_envsubst_vars()` | Needed for the new CronJob YAML that mounts `$ATLAS_ROOT` |
| 15 `*/prereqs.yaml` files | Converted NFS PV+PVC pairs to Longhorn PVCs (dynamic provisioning) | All state moved from NFS to Longhorn; static PV blocks removed |

---

## 7. Key Learning Points

1. **Unix permissions are not the whole story.** When `root` gets `Permission denied` on a file it owns, SELinux is the next thing to check. Always run `ls -laZ` or `getfattr -n security.selinux` before assuming a Unix permission bug.

2. **MCS categories persist on persistent volumes.** Files carry their creator's MCS categories forever, even after the creator pod is deleted. Any pod mounting the same PVC gets different categories by default and can't access those files.

3. **`seLinuxOptions` at the container level does not control MCS.** Kubernetes assigns MCS categories at the pod level. Setting `level: s0` on a container is silently ignored for category purposes. Always set it on `spec.securityContext` (pod level).

4. **`privileged: true` bypasses enforcement but doesn't prevent labeling.** A privileged container can read anything, but the files it creates still get labeled with its MCS categories. The downstream reader (workload pod) may not be privileged and will hit denials.

5. **`setroubleshootd` high CPU is a symptom, not a problem.** It's chewing through a denial backlog. Fix the denials and it will idle. Don't mask it — use it as a canary.

6. **Backup pods touch production PVCs.** Our backup and restore utility pods both mount live PVCs. Any file they create (even a tiny `__backup_timestamp.txt`) can trigger a cascade of WAL-related `{ lock }` denials on SQLite-backed workloads. These pods need the same pod-level `seLinuxOptions` fix as the restore pods.

7. **io_uring denials are audit spam, not functional breakage.** Both Python asyncio and Node.js libuv fall back to `epoll` when `io_uring_setup()` returns EACCES — the app keeps working. But they retry periodically, generating continuous denials that keep `setroubleshootd` busy and fill the audit log. The fix is app-level (`PYTHON_IO_URING=0` or `UV_USE_IO_URING=0`), which skips the doomed syscall entirely. There is no SELinux boolean for io_uring — the only bypass is `privileged: true`.
