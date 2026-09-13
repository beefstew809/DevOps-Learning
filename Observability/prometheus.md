# Prometheus

https://prometheus.io/docs/

A time-series database that **pulls** metrics over HTTP, stores them locally, and evaluates
rules. The pull model is the defining design choice: Prometheus discovers targets and scrapes
them, so it always knows whether a target is up — a push system cannot distinguish "nothing to
report" from "dead".

```
targets (/metrics)  ◄── scrape ── Prometheus ──► rules ──► Alertmanager ──► notification
                                       │
                                   Grafana queries it
```

## Exposition format

```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",status="200"} 14823
http_requests_total{method="POST",status="500"} 12
```

Plain text on `/metrics`. Anything that can serve HTTP can be a target. Check a target by hand
before debugging Prometheus:

```bash
curl -s localhost:9090/metrics | head -30
```

## Configuration

```yaml
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    cluster: home              # identifies this Prometheus in federated/remote setups

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ["docker1:9100", "docker2:9100"]

  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # only scrape pods with prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      # let the pod choose its port
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
```

**`scrape_interval` is the resolution limit of everything downstream.** A 60s interval cannot
show a 20-second spike, and `rate()` over a window shorter than ~4× the interval returns
nothing. 15–30s is the usual choice.

Relabelling is the hardest part of Prometheus config. `relabel_configs` runs **before** the
scrape and decides what to scrape and how to label it; `metric_relabel_configs` runs
**after** and filters the metrics themselves. Use the first to control targets, the second to
drop expensive series.

## PromQL

### Selecting

```promql
http_requests_total
http_requests_total{job="api", status=~"5.."}
http_requests_total{status!~"2.."}
http_requests_total[5m]                      # range vector — for rate()
```

Matchers: `=`, `!=`, `=~` (regex), `!~`. Regexes are anchored automatically, so `status=~"5.."`
matches exactly three characters.

### Rates — the thing to get right

```promql
rate(http_requests_total[5m])        # per-second average over 5m, handles counter resets
irate(http_requests_total[5m])       # uses last two samples — spiky, for graphs only
increase(http_requests_total[1h])    # total over the window
```

**Always `rate()` a counter, never graph it raw** — the raw value is a monotonically rising
line that tells you nothing.

The ordering rule that trips everyone: **`rate()` goes innermost, `sum()` outside.**

```promql
# RIGHT
sum(rate(http_requests_total[5m])) by (status)

# WRONG — sum of counters resets to a garbage value whenever any pod restarts
rate(sum(http_requests_total)[5m:])
```

Window length should be at least 4× the scrape interval. Too short and you get gaps; too long
and you smooth away the event.

### Aggregating

```promql
sum by (namespace) (rate(container_cpu_usage_seconds_total[5m]))
avg without (instance) (node_load1)
count by (job) (up == 1)
topk(5, sum by (pod) (container_memory_working_set_bytes))
```

`by` keeps only the listed labels; `without` drops the listed ones and keeps the rest.
`without` survives new labels appearing, which makes it the more robust choice.

### Percentiles

```promql
histogram_quantile(0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)
```

The `le` label must be preserved — `histogram_quantile` needs the buckets. Dropping it in the
`by` clause yields `NaN`, which is the usual mistake.

Accuracy is bounded by bucket boundaries. If your buckets stop at 1s, a p99 of 4s reports as
`+Inf`-ish nonsense. Choose buckets spanning your real latency range.

### Arithmetic between series

```promql
# error ratio
sum(rate(http_requests_total{status=~"5.."}[5m]))
  / sum(rate(http_requests_total[5m]))

# memory as a fraction of limit
container_memory_working_set_bytes
  / on (pod, container) kube_pod_container_resource_limits{resource="memory"}
```

Binary operations match series by **identical label sets**. Different labels produce an empty
result, which is the most confusing failure in PromQL. Fix it with `on()` / `ignoring()`:

```promql
metric_a / on (pod) metric_b
metric_a / ignoring (instance) metric_b
sum(rate(x[5m])) / scalar(sum(rate(y[5m])))     # force one side to a scalar
```

Empty result with no error nearly always means label mismatch. Run each side separately and
compare label sets.

### Useful patterns

```promql
# is it up
up{job="node"} == 0

# disk full in 4 hours, based on the last 6h trend
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 4*3600) < 0

# restarting pods
increase(kube_pod_container_status_restarts_total[1h]) > 3

# certificate expiring within a week
probe_ssl_earliest_cert_expiry - time() < 7*86400

# a metric that disappeared (target gone)
absent(up{job="critical-app"})
```

`predict_linear` for disk is far better than a static threshold: it fires on trajectory, so a
slowly filling disk pages you with hours of warning and a 90%-but-stable disk does not page at
all.

## Recording rules

Pre-compute expensive queries so dashboards and alerts are fast and consistent:

```yaml
groups:
  - name: api
    interval: 30s
    rules:
      - record: job:http_request_error_rate:ratio5m
        expr: |
          sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
            / sum by (job) (rate(http_requests_total[5m]))
```

The `level:metric:operation` naming convention is worth following. Use recording rules for
anything referenced by several alerts or panels — it removes the chance of two definitions
drifting apart.

## Alerting rules

```yaml
groups:
  - name: slo
    rules:
      - alert: HighErrorRate
        expr: job:http_request_error_rate:ratio5m{job="api"} > 0.05
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.job }} error rate {{ $value | humanizePercentage }}"
          runbook: "https://wiki.example.com/runbooks/high-error-rate"
```

**`for:` is what separates a useful alert from a pager nuisance.** The condition must hold
continuously for that duration; a 30-second blip never fires. Without `for:`, any single
scrape can page someone.

Every alert should carry: a severity, a summary naming the affected thing, and a **runbook
link**. An alert that does not say what to do is an interruption, not information.

```bash
promtool check rules /etc/prometheus/rules/*.yml
promtool check config /etc/prometheus/prometheus.yml
promtool query instant http://localhost:9090 'up == 0'
```

`promtool check rules` in CI catches broken expressions before they silently stop alerting —
a failure mode you otherwise discover during an incident.

## Alertmanager

Grouping, inhibition and routing live here, not in Prometheus.

```yaml
route:
  receiver: default
  group_by: [alertname, cluster, namespace]
  group_wait: 30s          # wait for related alerts before the first notification
  group_interval: 5m       # wait before notifying about NEW alerts in an existing group
  repeat_interval: 4h      # re-notify about a still-firing alert
  routes:
    - matchers: [severity="critical"]
      receiver: pager
    - matchers: [severity="warning"]
      receiver: chat

inhibit_rules:
  - source_matchers: [alertname="NodeDown"]
    target_matchers: [severity="warning"]
    equal: [node]

receivers:
  - name: pager
    webhook_configs:
      - url: "https://ntfy.example.com/alerts"
```

Two features that matter more than they sound:

- **Grouping** turns a node failure into one notification instead of forty. `group_by` choice
  decides how coarse that is.
- **Inhibition** suppresses consequences when the cause is already firing — no "pod
  unreachable" pages while "node down" is active.

```bash
amtool alert query
amtool silence add alertname=HighErrorRate --duration=2h --comment="deploying fix"
```

Silence before planned work. An alert that fires during a known maintenance window erodes trust
in every other alert.

## Storage and retention

Local TSDB, ~1–2 bytes per sample after compression.

```
--storage.tsdb.retention.time=30d
--storage.tsdb.retention.size=100GB
```

Prometheus is **not** built for long retention or horizontal scale. When you outgrow it:

- **Thanos** or **Mimir** — remote storage in object storage, global query view, downsampling.
- **Federation** — a parent scrapes aggregated series from children. Simple; do not federate
  raw metrics, only recording-rule outputs.
- **remote_write** to a managed backend.

Prometheus HA is **two identical instances scraping the same targets**, not clustering.
Alertmanager deduplicates the resulting duplicate alerts. There is no leader election.

## Kubernetes

Use **kube-prometheus-stack**: Prometheus Operator, Prometheus, Alertmanager, Grafana,
node-exporter, kube-state-metrics and a large set of working default rules.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

The Operator means scrape config becomes objects:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp
  labels:
    release: monitoring          # must match the Prometheus's serviceMonitorSelector
spec:
  selector:
    matchLabels:
      app: myapp
  endpoints:
    - port: metrics              # the Service's PORT NAME, not a number
```

Two things that cause "my ServiceMonitor is ignored":

- The label must satisfy the Prometheus resource's `serviceMonitorSelector`. Check it:
  `kubectl get prometheus -o yaml | grep -A5 serviceMonitorSelector`.
- `port` is the **name** of the port on the Service. A numeric value does not match.

Know the difference between the two metric sources: **node-exporter** reports host-level
metrics; **kube-state-metrics** reports the state of Kubernetes *objects* (desired replicas,
pod phase, resource limits). Questions like "is this Deployment at its desired count" need
kube-state-metrics, not cAdvisor.

## Troubleshooting

```bash
# what Prometheus thinks of its targets — first stop
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] |
  select(.health!="up") | {job:.labels.job, url:.scrapeUrl, err:.lastError}'

# does the series exist at all?
curl -s 'localhost:9090/api/v1/series?match[]=http_requests_total' | jq '.data | length'

# TSDB health and cardinality
curl -s localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:10]'
```

| Symptom | Cause |
| --- | --- |
| Target `DOWN`, `connection refused` | App not listening, wrong port, NetworkPolicy |
| Target missing entirely | Relabel rule dropped it; check `keep`/`drop` regexes |
| Query returns nothing, no error | Label mismatch in a binary op, or typo in a label value |
| `rate()` empty | Window shorter than ~4× scrape interval, or the counter never increments |
| `histogram_quantile` → `NaN` | `le` dropped by aggregation, or no observations |
| Memory climbing steadily | Cardinality — check `status/tsdb` |
| Alert never fires | `for:` too long, or `promtool` would reject the rule |

Prometheus memory use is driven almost entirely by the number of active series. An OOM is
nearly always a cardinality problem, not a retention one.

## Related

- [observability-fundamentals.md](observability-fundamentals.md) — what to measure, cardinality
- [logging-and-alerting.md](logging-and-alerting.md)
- [../Container Orchestration/kubernetes/kubernetes-troubleshooting.md](../Container%20Orchestration/kubernetes/kubernetes-troubleshooting.md)
