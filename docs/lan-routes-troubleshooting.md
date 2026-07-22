# LAN Routes Troubleshooting: A Deep Dive

This document explains the journey of debugging why `*.lan.local` routes failed
on a newly set up K3s node. It is written for someone with basic networking
knowledge (IP addresses, subnets, ports, firewalls) and Linux familiarity. Every
new concept is explained as it appears.

---

## 1. The Problem

When setting up a new K3s node for the first time, everything worked except
LAN-only routes (`tv.lan.local`, `send.lan.local`). These returned **"connection
refused"** — a TCP-level error meaning nothing accepted the connection on port
443.

Public routes (`tv.home.example.org`, etc.) worked fine through the same Traefik
ingress controller on the same port.

The problem persisted even with `firewalld` disabled and the WireGuard VPN
turned off.

---

## 2. Architecture Overview

To understand the problem, you need to understand how traffic reaches
applications on the cluster. There are two paths:

### 2.1 Public traffic (Internet → FRP → srv0)

```
Internet client
    │
    ▼
vps0 (edge VPS)
    │  Traefik terminates TLS
    │  Adds PROXY protocol header (more on this later)
    │  Forwards to FRP server
    ▼
FRP tunnel (encrypted TCP tunnel over the internet)
    │
    ▼
srv0 (home server)
    │  FRP client receives traffic
    │  Forwards to localhost:8443
    ▼
srv0 K3s Traefik
    │  Reads PROXY protocol → knows real client IP
    │  Routes to correct backend pod
    ▼
Application pod (Jellyfin, Gokapi, etc.)
```

### 2.2 LAN traffic (Direct access)

```
LAN client (192.168.0.x)
    │  Connects directly to srv0:443
    ▼
srv0 K3s Traefik
    │  No proxy protocol
    │  Routes to correct backend pod
    ▼
Application pod
```

---

## 3. The Troubleshooting Journey

### 3.1 First Discovery: Certificates Were Healthy

We started by checking the live cluster. The `local-tls` TLS certificate
(used by `*.lan.local` routes) was present, valid, and properly issued by
cert-manager. The IngressRoutes existed and matched correctly.

However, we noticed that `curl` to `tv.lan.local` from *within* the node
returned `400 Bad Request`, not a working response. This ruled out "connection
refused" being the *only* symptom — something deeper was wrong.

### 3.2 The Certificate Race Condition

**Background: cert-manager.** cert-manager is a Kubernetes addon that
automatically issues and renews TLS certificates. It uses "Issuers" to create
"Certificate" resources, which become Kubernetes Secrets containing the actual
TLS key pair.

Our `local-tls` certificate for `*.lan.local` follows this chain:

```
self-signed-issuer → k3s-local-ca (CA certificate) → ca-issuer → local-tls
```

Each step depends on the previous one. The CA certificate must be issued before
the CA issuer can work, which must be ready before `local-tls` can be issued.

**The bug:** In `cert-manager/post.sh`, the script applied all these resources
at once without waiting for each step to complete. On a fresh node, cert-manager
hadn't finished issuing the CA cert when `local-tls` was requested. This could
delay the `local-tls` secret from being created.

**Fix:** Added explicit waits in `post.sh` for each certificate in the chain to
reach "Ready" status before proceeding.

### 3.3 The Proxy Protocol Problem

**Background: PROXY protocol.** When a reverse proxy forwards a TCP connection,
the backend normally sees the proxy's IP as the client, losing the real client
IP. The PROXY protocol solves this: the proxy prepends a small header to the TCP
stream containing the real client's IP address. The backend reads this header,
strips it, and processes the rest normally.

Our vps0 Traefik adds a PROXY protocol v2 header before forwarding traffic to
the FRP tunnel. This lets srv0's Traefik know the real client IP for features
like geoblocking (blocking by country) and CrowdSec (intrusion prevention).

The problem was in srv0's Traefik configuration:

```yaml
proxyProtocol.trustedIPs=127.0.0.1/32,10.42.0.0/16,10.43.0.0/16
```

This tells Traefik: "Expect PROXY protocol headers from connections originating
from these IP ranges." The `10.42.0.0/16` range is the Kubernetes pod network.

#### Why This Is a Problem: Klipper and SNAT

**Background: ServiceLB / Klipper.** K3s comes with a built-in load balancer
called Klipper (also known as ServiceLB). When you create a Kubernetes Service
of type `LoadBalancer`, Klipper creates a pod that listens on the host's ports
and forwards traffic to the service. It uses iptables rules (the Linux kernel's
built-in firewall and packet routing system) to do this.

**Background: SNAT (Source Network Address Translation).** When Klipper forwards
a connection, it changes the source IP of the packet so that response traffic
flows back through Klipper correctly. This process is called SNAT or
"masquerading." Without it, the backend would try to respond directly to the
original client, which wouldn't work because the client expects responses from
the node's IP, not some internal pod IP.

Because of SNAT, Traefik sees *all* incoming connections as coming from
`10.42.0.x` (the pod network), regardless of whether the original client is:

- A LAN computer at `192.168.0.x`
- The FRP container at `127.0.0.1` (localhost)
- A pod inside the cluster

Since `10.42.0.0/16` was in the PROXY protocol trusted IPs, Traefik expected
PROXY protocol from **every** connection. But only FRP traffic (from vps0)
actually included it.

**The result:**
- FRP traffic → has PROXY protocol → works ✓
- LAN traffic → no PROXY protocol → Traefik misreads the bytes → `400 Bad Request` ✗

#### The Fix: Dual Entrypoint Architecture

**Background: Traefik entrypoints.** An entrypoint is a port that Traefik
listens on. Each entrypoint can have different configuration (TLS settings,
middleware, etc.). An IngressRoute specifies which entrypoint(s) it should be
served on.

The solution was to split traffic across two entrypoints:

| Entrypoint | Port | PROXY Protocol | Used By |
|-----------|------|---------------|---------|
| `websecure` | 443 | No | LAN clients, direct access |
| `websecure-proxy` | 8443 | Yes | FRP traffic from vps0 |

- **LAN-only routes** (`*.lan.local`) only listen on `websecure:443`
- **Public routes** (`*.home.example.org`) listen on **both** entrypoints

This way:
- LAN clients connect to port 443 → no proxy protocol expected → works
- FRP traffic arrives on port 8443 → proxy protocol expected → real client IP preserved for geoblocking/CrowdSec

We also changed the FRP client to forward to port 8443 instead of 443.

### 3.4 The Authelia ForwardAuth Issue

**Background: Authelia and forward auth.** Authelia is a Single Sign-On (SSO)
proxy. Traefik's `forwardAuth` middleware sends an authentication check request
to Authelia for every incoming request. If the user isn't logged in, Authelia
returns a redirect (302) to the login page.

When we tested after the entrypoint fix, LAN routes worked from the node but
returned `400 Bad Request`. The Authelia logs revealed why:

```
error: no configured session cookie domain matches the url 'https://tv.lan.local/'
```

Authelia manages login sessions via cookies tied to specific domains (like
`home.example.org`). It doesn't know about `*.lan.local` domains, so it rejects
LAN route authentication requests with a 400 error.

**Why this didn't matter on fresh nodes:** The LAN-only IngressRoutes have
`# IGNORE INITIALLY` markers on the `forwardauth-authelia` middleware lines.
During initial deployment (`k3s deploy --initial`), these lines are stripped —
the LAN routes have no authentication. This is by design: during first-time
setup, you need unauthenticated access via LAN to configure services.

After initial setup, running a regular deploy adds the authentication back, but
Authelia can't handle `*.lan.local`. The fix was to re-deploy in initial mode.

### 3.5 The kube-router Network Policy Problem

After all the above fixes, LAN routes worked from the node itself but returned
**"connection refused"** from other computers on the LAN.

**Background: Kubernetes Network Policies and kube-router.** A NetworkPolicy is
a firewall rule for pods. It controls which traffic can enter (ingress) and
leave (egress) a pod. K3s uses `kube-router` to enforce these policies by
translating them into iptables rules.

**Background: iptables chains and rules.** iptables organizes rules into
"chains" — ordered lists checked against each packet. Common chains:

- `PREROUTING`: First chain a packet hits when arriving. Used for DNAT (changing
  the destination of packets).
- `FORWARD`: For packets passing *through* the system (not destined to a local
  process). Has a default `DROP` policy.
- `INPUT`: For packets destined to a local process.
- `POSTROUTING`: Last chain before a packet leaves. Used for SNAT (changing the
  source of packets).

Each NetworkPolicy becomes a set of iptables rules in kube-router's
`KUBE-ROUTER-FORWARD` chain. If no rule allows a packet, the FORWARD chain's
default `DROP` policy discards it — resulting in "connection refused" to the
client.

Our kube-system namespace had this NetworkPolicy for Traefik:

```yaml
ingress:
  - from:
      - namespaceSelector: {}    # Rule A: allow from any K8s namespace (all ports)
  - ports:                       # Rule B: allow specific ports from any source
      - port: 8000
      - port: 8443
```

These two rules are ORed together. A packet matches if EITHER rule applies:

- **Rule A**: Any pod in any Kubernetes namespace can reach Traefik on any
  port. This handles internal cluster traffic (health checks, metrics, pod-to-pod
  communication).
- **Rule B**: Traffic on ports 8000 and 8443 is allowed from *anywhere*
  (including external networks like your LAN). But port 443 is NOT in this list.

With the old architecture, port 443 was handled differently. With our new dual
entrypoint architecture, external LAN traffic arrives on port 443 — and
kube-router dropped it because the NetworkPolicy didn't allow port 443 from
external sources.

**Note:** The NetworkPolicy has two ingress rules, not one rule with two
sections. In Kubernetes YAML, each `-` under `ingress:` is a separate rule, and
rules are combined with OR logic. A common confusion is reading this as one
rule that requires *both* a namespace source *and* specific ports — that's not
how it works.

#### The Fix

Added ports `80` and `443` to the NetworkPolicy:

```yaml
- ports:
    - port: 80
    - port: 443
    - port: 8000
    - port: 8443
```

### 3.6 How We Diagnosed the Network Policy Issue

The diagnostic process used several iptables commands to trace the packet flow:

1. **`iptables -t nat -L PREROUTING -n -v`** showed that traffic to
   `192.168.0.XX:443` was being DNATed (redirected) to the Traefik pod — 1438
   packets matched. This meant the port forwarding *was* working.

2. **`iptables -L KUBE-ROUTER-FORWARD -n -v`** showed per-pod firewall chains.
   Finding the Traefik pod's IP (`10.42.0.41`) revealed the specific chain that
   filtered its traffic.

3. **`kubectl get networkpolicy`** confirmed the policy only allowed ports 8000
   and 8443 from external sources.

The key insight: "connection refused" at the TCP level means the SYN packet
either got a RST response (actively rejected) or was dropped. With the DNAT
working (packets being redirected) but no response, the packets were being
*dropped* by the FORWARD chain's default DROP policy.

---

## 4. All Changes Summary

| File | Change | Why |
|------|--------|-----|
| `k3s/traefik/traefik.yaml` | Split into `websecure:443` (no proxy protocol) and `websecure-proxy:8443` (proxy protocol) | Prevents PROXY protocol parsing from corrupting LAN traffic |
| `compose/templates/frpc/frpc.toml.secret` | FRP HTTPS proxy now connects to `localhost:8443` | Routes FRP traffic to the proxy-protocol-enabled entrypoint |
| 13 `k3s/*/ingress.yaml` files | Public IngressRoutes listen on both entrypoints; LAN routes stay on `websecure` only | Public routes accessible from both LAN and internet |
| `k3s/traefik/middlewares.yaml` | Added `trustForwardHeader: true` to forwardauth-authelia | Ensures Authelia receives proper X-Forwarded headers |
| `k3s/cert-manager/post.sh` | Added waits for CA cert and `local-tls` readiness | Prevents race condition where Traefik starts before TLS secrets exist |
| `k3s/namespaces/kube-system-policies.yaml` | Added ports 80 and 443 to allow-traefik-ingress policy | Allows external LAN traffic to reach Traefik on port 443 |

---

## 5. Key Networking Concepts

### TCP Connection States

| Error | Meaning |
|-------|---------|
| **Connection refused** | TCP RST packet received. Something is actively rejecting or the port is closed. iptables DROP also looks like this to the client (no response = timeout or RST). |
| **Connection timed out** | No response to TCP SYN. Usually a firewall silently dropping packets. |
| **400 Bad Request** | TCP connection succeeded. HTTP-level error — the server received the request but can't process it. |

### PROXY Protocol

A small binary header prepended to a TCP stream that tells the backend the real
client's IP address. Without it, a backend behind a proxy only sees the proxy's
IP. Version 1 is text-based (`PROXY TCP4 1.2.3.4 5.6.7.8 12345 443\r\n`).
Version 2 is binary and more efficient.

### SNAT / Masquerading

When a router/proxy forwards a connection, it must change the source IP of
outbound packets so response traffic comes back through the router. Without
this, the backend would try to respond directly to the client using an internal
IP the client doesn't know about. In iptables, this is called MASQUERADE.

### iptables Chains

iptables rules are organized into chains — ordered lists that each packet
traverses:

| Chain | When a packet enters | Typical use |
|-------|---------------------|-------------|
| PREROUTING | As soon as packet arrives (before routing decision) | DNAT (changing destination) |
| INPUT | Packet is destined for a local process | Firewall for local services |
| FORWARD | Packet is passing through (neither source nor dest is local) | Firewall for routed traffic |
| OUTPUT | Packet originates from a local process | Firewall for outbound traffic |
| POSTROUTING | Just before packet leaves (after routing decision) | SNAT (changing source) |

When you see "policy DROP" on a chain, it means packets that don't match any
rule are silently discarded.

### NetworkPolicy (Kubernetes)

A Kubernetes resource that acts as a firewall for pods. It specifies:
- Which pods it applies to (`podSelector`)
- What traffic is allowed in (`ingress`) and out (`egress`)
- Which sources/destinations are allowed

When no NetworkPolicy selects a pod, all traffic is allowed. When *any* policy
selects a pod, only traffic explicitly allowed by *some* policy is permitted.
This is called "deny-by-default after first policy."

### Klipper (K3s ServiceLB)

K3s's built-in load balancer. When you create a `LoadBalancer` type Service,
Klipper:
1. Creates a pod with `hostPort` set to the service ports
2. The pod runs iptables commands to DNAT traffic from the host port to the
   service's ClusterIP
3. kube-proxy then forwards to the actual backend pods

### ExternalTrafficPolicy

A Service setting that controls how source IPs are handled:
- `Cluster` (default): Traffic may be routed to any node, source IP is
  SNATed/masqueraded. The backend sees the node's IP, not the client's.
- `Local`: Traffic only routed to pods on the same node. Source IP is preserved.
  The backend sees the real client IP.

---

## 6. Key Learning Points

1. **"Connection refused" is not always a port problem.** A Kubernetes
   NetworkPolicy or iptables DROP can produce the same symptom as a closed port.

2. **PROXY protocol trusted IPs must match the actual source IPs seen by the
   backend.** When Klipper SNATs all traffic to appear from pod-network IPs,
   the trusted IPs must reflect that — or you must separate traffic onto
   different ports.

3. **Read the actual error response body.** When we initially saw `400 Bad
   Request`, we assumed it was proxy protocol corruption. But the Authelia logs
   revealed the real cause for the 400 (unknown session cookie domain).

4. **NetworkPolicy ingress rules are ORed, not ANDed.** Multiple entries under
   `ingress:` are separate allow rules, not combined conditions.

5. **`externalTrafficPolicy: Cluster` loses client IPs.** This is why the
   `lan-whitelist` middleware (which checks for private IPs) saw `10.42.0.x`
   from all clients — the original LAN IP was SNATed away. The IP whitelist
   still worked because `10.0.0.0/8` is in the allowed range, but this masks
   the true client identity.

6. **iptables `-v` (verbose) shows packet counters.** This is essential for
   diagnosis — it tells you whether packets are reaching a rule or being dropped
   earlier in the chain.
