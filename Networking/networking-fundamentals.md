# Networking Fundamentals

The layer under everything else in this repo. Container networking, Kubernetes Services, VPCs
and reverse proxies are all abstractions over these mechanics, and debugging them means
dropping to this level.

## The layers that matter

Seven-layer OSI is a teaching model; in practice four layers carry the traffic:

| Layer | Unit | Addressing | Where you meet it |
| --- | --- | --- | --- |
| **Link (2)** | Frame | MAC | Same subnet, ARP, VLANs |
| **Network (3)** | Packet | IP | Routing, NAT, firewalls, CIDR |
| **Transport (4)** | Segment | Port | TCP/UDP, NLB, security groups |
| **Application (7)** | Message | URL, hostname | HTTP, TLS, ALB, Ingress |

The useful habit is asking **which layer is failing**. "Cannot connect" at layer 3 (no route)
looks different from layer 4 (refused/filtered) and layer 7 (502, TLS error) — and each has
different tools.

## IP addressing and CIDR

```
10.0.1.37/24
└─ address   └─ prefix length: first 24 bits are the network
```

`/24` means 24 network bits and 8 host bits, so 256 addresses. The arithmetic worth memorising:

| Prefix | Addresses | Usable (normal subnet) |
| --- | --- | --- |
| `/32` | 1 | a single host |
| `/30` | 4 | 2 |
| `/29` | 8 | 6 |
| `/28` | 16 | 14 |
| `/24` | 256 | 254 |
| `/20` | 4,096 | 4,094 |
| `/16` | 65,536 | 65,534 |
| `/8` | 16,777,216 | — |

Two are normally unusable: the network address (all host bits 0) and the broadcast (all 1s).
Cloud providers reserve more — AWS takes five per subnet.

**Each step down the prefix doubles the size.** `/23` is two `/24`s. That relationship is all
you need for subnetting on paper.

Private ranges (RFC 1918) — not routable on the internet:

```
10.0.0.0/8         10.0.0.0     – 10.255.255.255
172.16.0.0/12      172.16.0.0   – 172.31.255.255
192.168.0.0/16     192.168.0.0  – 192.168.255.255
100.64.0.0/10      carrier NAT — also what Tailscale and EKS secondary ranges use
169.254.0.0/16     link-local — 169.254.169.254 is cloud metadata
127.0.0.0/8        loopback
```

```bash
ipcalc 10.0.1.37/24          # or: sipcalc, or python3
python3 -c "import ipaddress as i; n=i.ip_network('10.0.0.0/20'); \
  print(n.num_addresses, n[0], n[-1], list(n.subnets(new_prefix=24))[:3])"
```

Plan ranges so they never overlap across environments or with on-premises. **Overlapping
networks cannot be routed between** — the fix is renumbering one side, which is expensive.

## TCP vs UDP

| | TCP | UDP |
| --- | --- | --- |
| Connection | Handshake | None |
| Delivery | Ordered, retransmitted | Best effort |
| Overhead | Higher | Minimal |
| Used by | HTTP, SSH, Postgres | DNS, QUIC, WireGuard, VXLAN |

The TCP handshake is worth knowing because its failure modes are diagnostic:

```
client → SYN      → server
client ← SYN-ACK  ← server
client → ACK      → server
```

| What you see | Meaning |
| --- | --- |
| `Connection refused` (RST) | Reached the host, **nothing listening** on that port |
| `Connection timed out` | No response at all — firewall dropping, or no route |
| `No route to host` | Local routing has nowhere to send it |
| Connects then hangs | Layer 7 — app accepted and is not responding |

**Refused versus timeout is the single most useful distinction in network debugging.** Refused
means connectivity works and the service is absent. Timeout means something silently discarded
the packet — a security group, NACL, iptables rule, or missing route. They point at completely
different things.

`TIME_WAIT` sockets accumulating after load is normal (the closing side holds the socket ~60s).
Thousands of them is only a problem if you exhaust ephemeral ports.

## DNS

Resolution order on Linux:

```
/etc/nsswitch.conf  →  /etc/hosts  →  DNS servers in /etc/resolv.conf
```

`/etc/hosts` wins. A stale entry there produces a failure that no amount of DNS debugging
explains, so check it first.

```bash
dig example.com                 # use dig, not ping, to test DNS
dig +short example.com
dig example.com @1.1.1.1        # bypass the local resolver
dig +trace example.com          # full delegation path from the root
dig -x 10.0.1.37                # reverse
dig example.com MX
dig example.com SOA +short      # which nameserver is authoritative
```

`ping` conflates DNS, routing and ICMP. `dig` tests only resolution — which is why it is the
right tool.

| Record | Purpose |
| --- | --- |
| `A` / `AAAA` | Name → IPv4 / IPv6 |
| `CNAME` | Alias to another name. **Cannot coexist with other records at the same name** |
| `MX` | Mail |
| `TXT` | SPF, DKIM, domain verification |
| `SRV` | Service discovery with port |
| `NS` | Delegation |

The CNAME restriction is why you cannot put a CNAME at the zone apex (`example.com`) — the apex
must hold `SOA` and `NS`. Providers work around it with `ALIAS`/`ANAME` (Route 53 alias
records).

### TTL and propagation

TTL is how long resolvers may cache an answer. "DNS propagation" is just waiting for caches to
expire.

**Lower the TTL before a planned change**, not during. Drop to 60s a day ahead, make the
change, restore it afterwards. Changing a record with a 24-hour TTL means up to 24 hours of
clients hitting the old address.

```bash
dig +noall +answer example.com        # shows remaining TTL, counting down
systemd-resolve --flush-caches        # or: resolvectl flush-caches
```

Negative answers are cached too (per the zone's SOA minimum), so a record created *after*
something looked it up may be invisible for a while.

## Routing and NAT

```bash
ip route                        # the routing table
ip route get 8.8.8.8            # which route WOULD be used — the precise question
ip addr
ip neigh                        # ARP cache
```

Longest prefix wins: a `/32` route beats `/24` beats the `0.0.0.0/0` default.

**NAT** rewrites addresses so many private hosts share one public IP. The consequences:

- Outbound works; **inbound needs an explicit port forward**.
- The server sees the NAT's address, not the client's — hence `X-Forwarded-For`.
- Two NATed networks with overlapping ranges cannot talk without double NAT.

Container networking is NAT: Docker's default bridge NATs containers behind the host, which is
why published ports are needed. Kubernetes deliberately avoids pod-to-pod NAT — see
[../Container Orchestration/kubernetes/kubernetes-networking.md](../Container%20Orchestration/kubernetes/kubernetes-networking.md).

### MTU

Maximum frame payload, normally 1500 bytes. Overlay networks (VXLAN, WireGuard, IPsec) add
headers, so the usable MTU inside a tunnel is smaller.

MTU mismatch produces a **distinctive symptom: small requests work, large ones hang.** TLS
handshakes complete, then a big response stalls. It happens when Path MTU Discovery fails
because something blocks ICMP "fragmentation needed".

```bash
ping -M do -s 1472 example.com     # 1472 + 28 headers = 1500; reduce until it passes
ip link set dev eth0 mtu 1450
```

If you ever see "works for small payloads, hangs for large" across a VPN or overlay, check MTU
before anything else.

## Ports and sockets

```bash
ss -tlnp                    # TCP listening, with process — replaces netstat
ss -tunap                   # TCP + UDP, all states
ss -s                       # summary
lsof -i :8080
```

`ss -tlnp` is the command to run when something "is not listening". Pay attention to the
address:

| Bind address | Reachable from |
| --- | --- |
| `127.0.0.1:8080` | **localhost only** |
| `0.0.0.0:8080` | all IPv4 interfaces |
| `[::]:8080` | all IPv6, usually IPv4 too via dual-stack |

**Binding to `127.0.0.1` inside a container means nothing outside the container can reach it.**
This is a top cause of a container that starts fine and refuses every connection. The app must
bind `0.0.0.0`.

Port ranges: 0–1023 privileged, 1024–49151 registered, 49152–65535 ephemeral. Rootless
containers cannot bind below 1024 without the sysctl — see
[../Containers/Podman/quadlets.md](../Containers/Podman/quadlets.md).

## Diagnostic toolkit

```bash
# is it listening locally?
ss -tlnp | grep 8080

# can I open a TCP connection? (layer 4, no app protocol)
nc -zv host 5432
timeout 3 bash -c '</dev/tcp/host/5432' && echo open || echo closed

# where do packets stop? (TCP, since ICMP is often blocked)
mtr -T -P 443 example.com
traceroute -T -p 443 example.com

# HTTP with timing breakdown
curl -w '
  dns:      %{time_namelookup}s
  connect:  %{time_connect}s
  tlsdone:  %{time_appconnect}s
  ttfb:     %{time_starttransfer}s
  total:    %{time_total}s
' -o /dev/null -s https://example.com

# what is on the wire
sudo tcpdump -i any -nn port 5432
sudo tcpdump -i any -nn 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0'
```

That `curl -w` timing breakdown is the fastest way to localise slowness: a large
`time_namelookup` is DNS, a large `time_connect` is network or backlog, a large
`time_appconnect` is TLS, and a large `time_starttransfer` with everything else small is the
application.

`tcpdump` for SYN/RST only is excellent for "is anything even arriving" — if you see the SYN
arrive and an RST leave, the host is reachable and refusing.

## TLS

```bash
openssl s_client -connect example.com:443 -servername example.com
openssl s_client -connect example.com:443 -showcerts </dev/null 2>/dev/null | openssl x509 -noout -dates -subject -issuer

# expiry, scriptably
echo | openssl s_client -connect example.com:443 2>/dev/null | \
  openssl x509 -noout -enddate
```

**`-servername` is required for SNI.** Without it you get the server's default certificate,
which looks like a misissued cert when the configuration is fine. Many "wrong certificate"
reports are a missing `-servername`.

Common failures:

| Error | Cause |
| --- | --- |
| `unable to get local issuer certificate` | Intermediate chain not served. Serve fullchain, not just the leaf |
| `certificate has expired` | Renewal failed — alert on expiry, it is entirely predictable |
| `hostname mismatch` | Certificate's SAN does not include the name used |
| `self signed certificate` | Private CA not in the client's trust store |
| `handshake failure` | No shared protocol version or cipher |

The missing-intermediate case is worth recognising: it often works in browsers (which cache
intermediates from other sites) and fails in `curl` and application HTTP clients. "Works in
Chrome, fails in the app" points straight at it.

Check what the chain actually looks like with `-showcerts` and count the certificates — a
single cert where there should be two or three is the problem.

## HTTP status codes, as signals

| Code | Means | Usual cause |
| --- | --- | --- |
| `301`/`308` | Permanent redirect | Cached aggressively by browsers — careful |
| `400` | Malformed request | Client |
| `401` / `403` | Unauthenticated / unauthorised | Credentials vs permissions |
| `404` | Not found | Route does not exist, or proxy path rewriting |
| `429` | Rate limited | |
| `499` | Client closed (nginx) | Client gave up — usually your backend is too slow |
| `500` | Application error | The app |
| `502` | Bad gateway | Proxy reached nothing, or got garbage. Backend down/wrong port |
| `503` | Unavailable | No healthy backends |
| `504` | Gateway timeout | Backend too slow for the proxy's timeout |

The proxy-side codes are the diagnostic ones: **502 means the backend is unreachable, 503 means
there are no healthy backends, 504 means it is alive but slow.** Three different
investigations.

## Tailnets and overlay networks

WireGuard-based mesh networks (Tailscale, Netbird) solve a real problem: connecting hosts
across NAT without port forwarding or a VPN concentrator.

What is useful to understand:

- Each node gets a stable address in `100.64.0.0/10`, routable only within the tailnet.
- NAT traversal is direct where possible, relayed otherwise. Relayed connections are slower —
  worth checking when throughput is poor.
- **MTU is reduced** by WireGuard's encapsulation. See the MTU section; this is the most common
  overlay problem.
- ACLs are the access control. A tailnet is flat by default, so anything joined can reach
  everything else.
- Subnet routers advertise an entire CIDR into the tailnet, which is how you reach non-tailnet
  hosts — and where overlapping ranges bite again.

```bash
tailscale status
tailscale ping <host>          # shows direct vs relayed (DERP)
tailscale netcheck
```

`tailscale ping` reporting a relayed path rather than direct is the answer to "why is this
slow".

## A debugging order that works

1. **DNS** — `dig` the name. Wrong answer, or no answer?
2. **Route** — `ip route get <ip>`. Is there a path?
3. **Port** — `nc -zv`. Refused (nothing listening) or timeout (filtered)?
4. **Bind address** — `ss -tlnp` on the server. `127.0.0.1` or `0.0.0.0`?
5. **Firewall** — security groups, NACLs, `iptables -L -n`, host firewall.
6. **TLS** — `openssl s_client` with `-servername`.
7. **Application** — `curl -w` timings, then logs.

Each step rules out a layer. Starting at step 7 is the usual mistake, and steps 1 and 3 resolve
most cases in under a minute.

## Related

- [dns-and-tls.md](dns-and-tls.md) — certificates and DNS operations in depth
- [../Container Orchestration/kubernetes/kubernetes-networking.md](../Container%20Orchestration/kubernetes/kubernetes-networking.md)
- [../Cloud/AWS/vpc-and-networking.md](../Cloud/AWS/vpc-and-networking.md)
- [../reverse_proxy/nginx.md](../reverse_proxy/nginx.md)
