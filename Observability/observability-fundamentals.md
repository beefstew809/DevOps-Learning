# Observability Fundamentals

Monitoring answers questions you knew to ask. Observability is the property of being able to
answer questions you did not anticipate — which in practice means having enough signal,
correlatable, to investigate a novel failure without shipping new code.

The distinction matters because dashboards full of CPU graphs are monitoring, and they do not
help when the failure is "checkout is slow for users in one region on one code path".

## The three signals

| Signal | Answers | Cost | Cardinality |
| --- | --- | --- | --- |
| **Metrics** | "Is it broken, how badly, since when" | Cheap, constant per series | Must stay **low** |
| **Logs** | "What exactly happened to this request" | Expensive, grows with traffic | Unlimited |
| **Traces** | "Where did the time go across services" | Moderate, usually sampled | High |

They have an order of use: metrics tell you *something* is wrong and alert you, traces tell
you *where*, logs tell you *why*. Skipping to logs is the common inefficiency — grepping for a
cause you could have localised in seconds with a trace.

## Metrics and the cardinality trap

A metric is a name, a set of labels, and a number over time. **Each unique label combination
is a separate stored time series.**

```
http_requests_total{method="GET", path="/api/users", status="200"} 14823
```

Multiply the distinct values of every label to get the series count:

```
10 paths × 5 methods × 6 statuses          = 300 series        fine
... × 50,000 user_ids                      = 15,000,000 series   system down
```

**Never label with user ID, request ID, session ID, email, full URL with query string, or
timestamp.** This is the single most common way to destroy a metrics backend, and it is
usually done with good intentions — wanting per-user visibility. Per-user detail belongs in
logs or traces, which are designed for unbounded dimensions.

```promql
# what is exploding
topk(10, count by (__name__)({__name__=~".+"}))
```

### Metric types

| Type | Meaning | Example |
| --- | --- | --- |
| **Counter** | Only increases; reset to 0 on restart | `http_requests_total` |
| **Gauge** | Goes up and down | `queue_depth`, `memory_bytes` |
| **Histogram** | Bucketed observations | `request_duration_seconds` |
| **Summary** | Client-computed quantiles | Rarely the right choice |

Counters are queried as rates, never as raw values — `rate()` handles the reset. Prefer
histograms to summaries: histogram buckets can be aggregated across instances, client-computed
quantiles cannot. **Averaging percentiles across pods is statistically meaningless**, and it is
a mistake that appears in a lot of dashboards.

## Averages lie; percentiles are the minimum

A 200 ms average request time is consistent with 95% of requests at 50 ms and 5% at 3
seconds. The average hides exactly the population you care about.

Always look at `p50`, `p95`, `p99`. And recognise that **p99 is every user's experience at
some point**: a page making 100 backend calls has a roughly even chance of hitting a p99 on
each load.

```promql
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
)
```

Tail latency is also where saturation shows first — it degrades long before averages move,
which makes p99 the earliest useful warning.

## What to actually measure

Two complementary frameworks, both better than instinct.

### The four golden signals (for services)

1. **Latency** — split successful from failed requests. Fast errors otherwise flatter your
   numbers.
2. **Traffic** — requests per second.
3. **Errors** — rate, and by class. A 4xx spike is a different problem from a 5xx spike.
4. **Saturation** — how full the most constrained resource is. The leading indicator.

### USE (for resources)

**Utilisation**, **Saturation**, **Errors** — for CPU, memory, disk, network. Saturation
(queue depth, run queue, IO wait) predicts trouble; utilisation only describes it. A disk at
100% utilisation with no queue is fine; at 60% with a deep queue it is not.

### What not to alert on

CPU usage, memory usage, disk IO, pod restarts, individual node health. These are
*diagnostic* signals. Alerting on them produces pages for conditions no user noticed, which
trains people to ignore pages.

**Alert on symptoms users experience**; use resource metrics to investigate. The exception is
genuinely predictive: disk filling within hours, certificate expiring in a week.

## SLIs, SLOs and error budgets

An **SLI** is a measurement of user-visible behaviour. An **SLO** is the target. An **error
budget** is the allowed shortfall.

```
SLI:  proportion of HTTP requests served < 300 ms with a non-5xx status
SLO:  99.9% over a rolling 30 days
budget: 0.1% → ~43 minutes of failure per 30 days
```

The error budget is what makes this more than a number on a slide:

- Budget remaining → ship features, take risks.
- Budget exhausted → stop feature work, spend it on reliability.

That converts an argument about whether to prioritise reliability into a measurement.

**Do not set 100%, and do not set the SLO higher than you need.** Every extra nine costs
disproportionately, and an SLO tighter than users actually require spends engineering on
nothing. Start from "what would make someone complain".

### Burn-rate alerting

Alerting on "SLO violated" is too late. Alert on how fast the budget is being consumed:

```promql
# fast burn: 14.4x normal rate — exhausts a 30-day budget in ~2 days. Page.
(
  sum(rate(http_requests_total{status=~"5.."}[5m]))
  / sum(rate(http_requests_total[5m]))
) > (14.4 * 0.001)
```

Pair a fast-burn alert (short window, pages) with a slow-burn one (long window, ticket). Two
windows per alert — a short one for sensitivity and a long one to suppress noise — is the
standard pattern and dramatically reduces false pages.

## Instrumenting: OpenTelemetry

OTel is the vendor-neutral standard for all three signals. The practical reason to use it:
instrument once, change backend later without touching application code.

```
app (OTel SDK) ──► OTel Collector ──► Prometheus / Loki / Tempo / a vendor
                     (receive, process, route)
```

Run the **Collector** rather than exporting straight to a backend. It gives you one place to
add metadata, drop high-cardinality labels, sample, batch, and switch destinations:

```yaml
receivers:
  otlp:
    protocols: { grpc: {}, http: {} }
processors:
  batch: {}
  memory_limiter:
    limit_mib: 512
  attributes:
    actions:
      - key: http.request.header.authorization     # never ship credentials
        action: delete
exporters:
  prometheus:
    endpoint: "0.0.0.0:8889"
  otlp/tempo:
    endpoint: tempo:4317
service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
    traces:
      receivers: [otlp]
      processors: [memory_limiter, attributes, batch]
      exporters: [otlp/tempo]
```

Auto-instrumentation gets HTTP, gRPC and database calls for free in most languages. Add manual
spans for business operations that matter.

## Correlation is the whole point

Three signals you cannot join are three silos. Make them joinable:

- **Trace ID in every log line.** This is the highest-value single change you can make —
  it turns "find the logs for this slow request" from a search into a lookup.
- **Exemplars on histograms** — attach trace IDs to metric buckets, so clicking a slow bucket
  on a graph jumps to a trace of an actual slow request.
- **Consistent resource attributes** — `service.name`, `service.version`, `deployment.environment`
  on everything.

```json
{
  "timestamp": "2026-09-12T14:23:11Z",
  "level": "error",
  "service": "checkout",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "user_id": "u_8812",
  "msg": "payment provider timeout",
  "provider": "stripe",
  "duration_ms": 5001
}
```

**Structured logs, always.** Unstructured text means writing parsers, and a format change
silently breaks them. Note `user_id` belongs here and *not* in a metric label.

## Sampling

At scale, keeping everything is unaffordable.

- **Head sampling** — decide at the start. Cheap, but you lose the interesting traces.
- **Tail sampling** — decide once the trace completes, so you can keep all errors and all slow
  requests while dropping most successes. Much better signal, needs the Collector to buffer.

```yaml
processors:
  tail_sampling:
    policies:
      - name: errors
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow
        type: latency
        latency: { threshold_ms: 1000 }
      - name: baseline
        type: probabilistic
        probabilistic: { sampling_percentage: 5 }
```

Keep **metrics unsampled** — they are cheap and they are what alerts fire on.

## Cost control

Observability bills get large quietly. The levers, in order of effect:

1. **Retention.** Most queries touch the last 48 hours. Keep raw data days, downsampled data
   months.
2. **Cardinality.** Drop labels you never group by.
3. **Log volume.** Debug logs in production at full volume are usually the largest line item.
   Sample them, or raise the level and rely on traces.
4. **Sampling traces** as above.
5. **Drop metrics nobody queries.** Most default exporter metrics are never looked at.

```yaml
# Prometheus: drop a noisy series at scrape time
metric_relabel_configs:
  - source_labels: [__name__]
    regex: 'go_gc_duration_seconds.*'
    action: drop
```

## Getting started, in order

1. **Uptime check from outside.** Blackbox probing catches the total outage that internal
   monitoring misses because it is also down.
2. **The four golden signals** on your main entry point.
3. **Structured logs with trace IDs.**
4. **One SLO** on the most important user journey, with burn-rate alerts.
5. **Traces** once more than two services are involved.
6. **Dashboards last.** Build them to answer questions you actually had during an incident,
   not to fill a screen.

Step 1 is genuinely first. A monitoring stack inside the cluster cannot tell you the cluster
is unreachable.

## Related

- [prometheus.md](prometheus.md) — querying and alerting
- [logging-and-alerting.md](logging-and-alerting.md) — Loki, routing, on-call
- [../Container Orchestration/kubernetes/kubernetes-troubleshooting.md](../Container%20Orchestration/kubernetes/kubernetes-troubleshooting.md)
