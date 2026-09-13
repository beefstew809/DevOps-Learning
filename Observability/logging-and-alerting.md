# Logging, Dashboards and On-Call

The operational half of observability: getting logs somewhere searchable, building dashboards
people actually use, and alerting in a way that does not burn out whoever carries the pager.

## Logging

### Structured, always

```
# unparseable without a regex that will break
2026-09-12 14:23:11 ERROR payment failed for user 8812 after 5001ms

# queryable
{"ts":"2026-09-12T14:23:11Z","level":"error","service":"checkout",
 "trace_id":"4bf92f35...","user_id":"u_8812","msg":"payment provider timeout",
 "provider":"stripe","duration_ms":5001}
```

JSON costs a few bytes and removes an entire class of work. Every log line should carry:
timestamp, level, service, **trace ID**, and a stable `msg` — stable so you can group by it
even as the variable fields change.

Put variables in **fields, not in the message**. `"msg":"payment timeout","provider":"stripe"`
groups; `"msg":"payment timeout for stripe after 5001ms"` gives a unique message per
occurrence and cannot be counted.

### Write to stdout

In containers, log to stdout/stderr and let the platform collect it. Writing to files inside a
container means logs die with it, and log rotation becomes your problem inside every image.

```yaml
# Kubernetes rotates these per node; limit them
# kubelet: --container-log-max-size=10Mi --container-log-max-files=5
```

For Docker/Podman, cap them or a chatty container fills the disk:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

An unbounded container log filling `/var` is a genuinely common outage cause, and it takes the
node with it.

### Levels, used properly

| Level | For | In production |
| --- | --- | --- |
| `ERROR` | Something failed and needs attention | Always on |
| `WARN` | Unexpected but handled | Always on |
| `INFO` | Significant state changes | Usually on |
| `DEBUG` | Developer detail | Off, or sampled |
| `TRACE` | Firehose | Off |

`DEBUG` at full volume in production is usually the largest line item on an observability
bill. Make the level runtime-configurable so you can raise it for one service during an
incident rather than redeploying.

### Never log

Passwords, tokens, API keys, full credit card numbers, session cookies, `Authorization`
headers, personal data beyond what you need. A logging pipeline is a data store with wide read
access — usually wider than the database the data came from.

Redact at the source, and again in the collector as a backstop (see the `attributes` processor
in [observability-fundamentals.md](observability-fundamentals.md)). Assume anything logged is
retained and visible to everyone with log access.

## Loki

Prometheus' model applied to logs: index **labels** only, store the log content compressed in
object storage. That makes it cheap, and it means the label rules from metrics apply — **low
cardinality labels only**.

```
# GOOD
{namespace="prod", app="checkout", level="error"}

# BAD — a stream per user, which is how you kill Loki
{namespace="prod", app="checkout", user_id="u_8812"}
```

Each unique label combination is a **stream**. High-cardinality labels explode stream count
exactly as they explode series count in Prometheus. Keep `user_id` in the log *line*, where it
is searchable without being indexed.

### LogQL

```logql
{app="checkout"} |= "timeout"                              # substring
{app="checkout"} != "healthcheck"                          # exclude
{app="checkout"} |~ "timeout|refused"                      # regex
{app="checkout"} | json | duration_ms > 1000               # parse, then filter on a field
{app="checkout"} | json | level="error" | line_format "{{.msg}} {{.provider}}"

# metrics from logs
sum(rate({app="checkout"} | json | level="error" [5m])) by (provider)
count_over_time({app="checkout"} |= "timeout" [1h])
```

The pattern worth knowing: **`|= "substring"` before `| json`**. Filtering the raw line first is
far cheaper than parsing every line and then filtering — on a large range it is the difference
between a query that returns and one that times out.

Deriving metrics from logs (`rate(... | json | level="error")`) is useful when the app was never
instrumented, but it is slower and less reliable than a real counter. Use it to bootstrap, then
instrument properly.

### Collection

**Alloy** (formerly Promtail) on each node, or the OTel Collector if you are already running
one. The important part is attaching the same labels you use in Prometheus —
`namespace`, `pod`, `app` — so a dashboard can pivot from a metric spike to the matching logs.

## Dashboards

Most dashboards are never used. The ones that are share a few properties.

**Build them for a question.** "Is checkout healthy?" produces a useful dashboard; "metrics for
the checkout service" produces a wall of graphs.

A layout that works:

```
Row 1  the four golden signals, big, for THIS service
       traffic | error rate | p50/p95/p99 latency | saturation
Row 2  dependencies — database, cache, downstream services
Row 3  resources — CPU, memory, restarts
Row 4  deep detail, collapsed by default
```

Top-to-bottom in order of "what do I look at first". Anyone on call should be able to answer
"is it broken" from row 1 without scrolling.

Practical notes:

- **Use template variables** (`$namespace`, `$service`) so one dashboard serves every instance
  instead of fifty near-identical copies.
- **Label axes with units.** An unlabelled graph of `0.0043` is not information.
- **Fix the y-axis for percentages** to 0–100, or a flat 99.9% line looks like a crisis.
- **Annotate deploys.** Most incidents correlate with a change; seeing deploy markers on a
  latency graph answers the first question automatically.
- **Put dashboards in git.** Grafana's JSON is exportable, and the provisioning path means a
  dashboard edited in the UI is not lost on the next reconcile — and is reviewable.

```yaml
# Grafana sidecar picks this up automatically with the kube-prometheus-stack
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-dashboard
  labels:
    grafana_dashboard: "1"
data:
  checkout.json: |
    { ... }
```

## Alerting that works

### Every alert must be actionable

The test: *if this fires at 3am, is there something a human must do right now?* If not, it is
a dashboard panel or a ticket, not a page.

Three tiers:

| Tier | Meaning | Channel |
| --- | --- | --- |
| **Page** | User-visible, needs action now | Phone, push |
| **Ticket** | Needs action this week | Issue tracker |
| **Dashboard** | Context | Nowhere |

Most things teams alert on belong in the bottom two.

### Symptoms, not causes

```promql
# page on this — a user is affected
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.05

# do not page on this — it may be entirely fine
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.2
```

Cause-based alerts multiply: one database problem pages five times from five services. Symptom
alerts are fewer and each one means something real. Use causes for diagnosis once you are
looking.

### Alert fatigue is the actual failure mode

An on-call rotation that receives twenty pages a week stops reading them. That is worse than
no alerting, because it is indistinguishable from coverage.

Defences:

- `for:` on every alert — no single-scrape pages.
- Grouping and inhibition in Alertmanager.
- **Review fired alerts weekly.** For each: was action taken? If not, delete or downgrade it.
  This is the highest-value recurring observability task and the one most often skipped.
- Silence during planned work.
- Track pages per on-call shift as a number you try to reduce.

### Runbooks

Every alert links to one. A usable runbook is short and specific:

```markdown
## HighErrorRate — checkout

**Means:** >5% of checkout requests returning 5xx for 10+ minutes. Users cannot buy.

**Check first:**
1. Recent deploy? `kubectl rollout history deployment/checkout -n prod`
2. Dashboard: which dependency? (row 2)
3. `{app="checkout"} | json | level="error"` — group by provider

**Known causes:**
- Stripe timeouts → check status.stripe.com; the circuit breaker should open itself
- DB connection exhaustion → `pg_stat_activity`; consider restarting the pooler

**Mitigation:** `kubectl rollout undo deployment/checkout -n prod` if a deploy correlates.
Self-heal is ON in ArgoCD, so commit the revert too or it will be re-applied.

**Escalate:** #payments, then the on-call lead after 30 minutes.
```

That last note about ArgoCD self-heal is exactly the kind of local detail a runbook exists to
carry — see [../GitOps/argocd.md](../GitOps/argocd.md).

## Incidents

A workable lightweight process:

1. **Declare it.** Naming it creates a channel and a timeline, and stops three people
   independently debugging.
2. **Assign roles** for anything non-trivial: someone coordinating, someone investigating,
   someone communicating.
3. **Mitigate before diagnosing.** Roll back, fail over, scale up. Understanding can wait;
   users cannot.
4. **Keep a timeline** as you go — timestamps, what you observed, what you changed. Writing it
   afterwards from memory does not work.
5. **Communicate** on a schedule, even with nothing new.
6. **Write a postmortem.**

### Postmortems

Blameless, and specific about it: the question is *what about the system allowed a reasonable
person to cause this*. "Someone ran the wrong command" is not a cause — the absence of a
confirmation prompt, or of a staging environment, is.

Contents that matter: impact in user terms and duration, the timeline, contributing factors,
what detection looked like (**how long until you knew** — often the biggest finding), and
action items with owners and dates.

Track **time to detect** separately from time to resolve. A two-hour outage detected after 90
minutes is a monitoring problem, not a reliability one, and the fix is different.

## Uptime checks from outside

The thing to set up first and the easiest to forget. Internal monitoring cannot report that
the whole stack is unreachable.

```yaml
# Prometheus blackbox exporter
- job_name: blackbox
  metrics_path: /probe
  params:
    module: [http_2xx]
  static_configs:
    - targets:
        - https://app.example.com/healthz
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - target_label: __address__
      replacement: blackbox-exporter:9115
```

Run this from somewhere that is **not** the thing it watches — a different host, a different
provider, or a hosted checker. A blackbox exporter inside the cluster it probes goes down with
it.

```promql
probe_success == 0
probe_ssl_earliest_cert_expiry - time() < 14*86400
```

Certificate expiry deserves its own alert. It is entirely predictable, entirely preventable,
and still a recurring cause of outages.

## Related

- [observability-fundamentals.md](observability-fundamentals.md) — signals, SLOs, burn rate
- [prometheus.md](prometheus.md) — rules and Alertmanager config
- [../GitOps/argocd.md](../GitOps/argocd.md) — self-heal fighting manual mitigation
