# AI for Development

Practical use of LLM coding assistance, with the failure modes that matter. The short version:
**the model is fast at producing plausible code and has no way to know whether it is correct.**
Every workflow below exists to close that gap.

## Where it helps and where it does not

| Works well | Works badly |
| --- | --- |
| Boilerplate, scaffolding, config files | Novel algorithms with correctness requirements |
| Translating between languages and formats | Anything depending on undocumented internal behaviour |
| Test generation from existing code | Choosing architecture for a system it cannot see |
| Explaining unfamiliar code | Recalling current APIs of fast-moving libraries |
| Reviewing a diff for a specific class of bug | Large refactors touching many invariants at once |
| Writing the first draft of documentation | Knowing whether your production data looks like your sample |

The pattern: it is strong where the answer is **determined by context you can supply** and weak
where it depends on knowledge it cannot verify.

## Three tiers — pick the cheapest that works

Reaching for an agent when a single call would do is the most common waste.

| Tier | Shape | Use for |
| --- | --- | --- |
| **Single call** | One prompt, one answer | Explain this, write this function, review this diff |
| **Workflow** | You orchestrate several calls in code | Classify then route, extract then validate, map over files |
| **Agent** | Model decides its own steps and tool calls | Multi-step tasks you cannot fully specify up front |

Before choosing the agent tier, check four things: is the task genuinely hard to specify in
advance; does the outcome justify higher cost and latency; is the model actually capable at it;
and **can errors be caught and recovered from** — tests, review, rollback. If any answer is no,
drop a tier.

An agent with no verification loop is a machine for generating plausible changes.

## Context is the actual skill

Output quality tracks context quality more than prompt wording. What to supply:

- **The real code**, not a paraphrase. Relevant files, and the interfaces it must satisfy.
- **Conventions**, so output matches the codebase rather than the model's average. A
  `CLAUDE.md` / `AGENTS.md` at the repo root carrying build commands, layout, and house style
  is the highest-leverage file you can write.
- **The failing output** — the actual error and stack trace, not "it doesn't work".
- **Constraints**: the library version, the target runtime, what must not change.

And what to leave out. Long context is not free: it costs money, it slows responses, and
irrelevant material measurably degrades attention on the parts that matter. Twenty files when
three would do makes results worse, not safer.

### Training cutoff is a real constraint

Any model has a knowledge cutoff, and library APIs move. Patterns that were correct a year ago
are confidently reproduced after they are wrong — deprecated parameters, renamed methods, removed
flags. The model cannot tell the difference between "I know this" and "I knew this".

Two defences:

1. **Supply current documentation in context** rather than trusting recall. Fetch the docs, paste
   the relevant section, or use a docs tool.
2. **Run the code.** A compiler or test suite settles it immediately.

This is not hypothetical: the right way to use an unfamiliar API is to read its current reference
and write against that, and to treat any remembered signature as a hypothesis.

## Verification is the whole job

The generated code is a proposal. Your workflow decides whether a wrong proposal reaches
production.

1. **Read it.** If you cannot explain why it works, you cannot maintain it, and review from the
   next person will not catch what you did not understand.
2. **Run it**, including the paths the happy case does not cover.
3. **Test it.** Prefer writing the test first and letting the model satisfy it — the test is a
   specification the model cannot argue with.
4. **Diff it.** Review AI-authored changes at least as carefully as a colleague's. The failure
   mode is *plausible*, which is exactly what skimming misses.

The trap is that output quality is high enough to disarm scrutiny. Human-written bugs usually
look wrong somewhere; generated bugs are well-formatted, conventionally named, and confidently
commented. **Fluency is not evidence.**

### Make the model check its own work

Cheap and effective:

```
Before answering, list the assumptions you are making about the codebase.
Then, after writing the code, identify the three most likely ways it is wrong.
```

Also useful: ask for the failure cases, ask it to write the test that would catch a bug in its
own output, and ask it to argue against its own design. A second pass reviewing the first pass
finds real problems — and a fresh session reviewing a diff with no memory of writing it finds
more.

## Specific failure modes

| Failure | Description | Defence |
| --- | --- | --- |
| **Plausible-but-wrong** | Correct-looking code with a subtle logic error | Tests, review, run it |
| **Hallucinated packages** | Imports a package that does not exist — or that an attacker registered with that name ("slopsquatting") | **Verify every new dependency exists and is the one you want** |
| **Stale APIs** | Deprecated or removed parameters from training data | Current docs in context; compile |
| **Silent scope creep** | Refactors things you did not ask about | Small diffs; review every hunk |
| **Confident wrong answers** | No calibrated uncertainty | Ask for alternatives and assumptions |
| **Losing the thread** | Long sessions drift from original constraints | Restate requirements; start fresh sessions |
| **Over-engineering** | Abstractions for requirements you do not have | Say "simplest thing that works" |
| **Test theatre** | Tests asserting the implementation, not behaviour | Review tests as carefully as code |

**Hallucinated dependencies are a supply-chain risk**, not just an error. A suggested package
name that does not exist can be registered by someone else; the next person who accepts the
suggestion installs their code. Treat every new import as something to verify in the real
registry before it enters a lockfile.

## Security

**Never paste into a prompt:** credentials, private keys, customer data, internal hostnames and
topology you would not publish, or proprietary code your agreements do not permit sharing. Assume
prompts may be logged or retained unless you have a contractual guarantee otherwise.

Other standing concerns:

- **Generated code has unclear provenance.** It may closely reproduce training material. For
  anything licence-sensitive, review rather than assume.
- **Generated code is not security-reviewed.** Models reproduce the patterns they saw, including
  insecure ones — string-concatenated SQL, missing authorisation checks, weak defaults. Scan it
  like any other code.
- **Agents with tool access inherit your permissions.** An agent that can run shell commands can
  do anything you can. Run it with the narrowest credentials that work, and in a sandbox or
  worktree for anything destructive.
- **Prompt injection through content.** An agent that reads a web page, issue comment, or log
  line is reading untrusted text that may contain instructions. Never let tool output authorise
  an action; keep a human gate on anything irreversible.

## Cost

If you are calling an API rather than using a subscription tool, cost is controllable and mostly
ignored.

Current first-party Claude pricing, per million tokens:

| Model | Input | Output |
| --- | --- | --- |
| Claude Opus 5 (`claude-opus-5`) | $5 | $25 |
| Claude Sonnet 5 (`claude-sonnet-5`) | $2 | $10 |
| Claude Haiku 4.5 (`claude-haiku-4-5`) | $1 | $5 |

Prices and model lineups change — check the live pricing page rather than trusting a table in a
repo, including this one.

Levers, cheapest effort first:

1. **Prompt caching.** Reusing a large stable prefix (a system prompt, a codebase excerpt, a tool
   list) across requests cuts input cost substantially. It is a **prefix match**, so order
   matters: stable content first, volatile content (timestamps, the current question) last. Any
   byte change invalidates everything after it. Verify it is working by checking that
   `cache_read_input_tokens` is non-zero across repeated requests — a `datetime.now()` in a system
   prompt silently disables caching with no error.
2. **Input hygiene.** Stop sending files the task does not need.
3. **Output limits.** Output tokens cost ~5× input. Ask for a diff, not the whole file.
4. **Batch API** for anything not latency-sensitive — roughly half price, asynchronous.
5. **Effort / reasoning depth.** Lower settings cost less and are often sufficient for routine
   work; raise them for genuinely hard problems rather than globally.
6. **Model choice.** Measure before downgrading. Judge **cost per completed task**, not per
   request — a cheaper model that needs three attempts and a human fix is not cheaper.

## Extending the tooling

- **Repo instructions** (`CLAUDE.md`, `AGENTS.md`) — conventions, commands, gotchas. Loaded
  automatically by most coding tools. Start here; it pays back immediately.
- **Skills** — packaged instructions for a recurring task ("how we do deploys", "our review
  checklist") that load when relevant.
- **MCP servers** — give a model structured access to a system: a git forge, a database, a
  ticket tracker, cloud APIs. Much more reliable than screen-scraping a CLI, because the tool
  schema is explicit.

On MCP specifically: **an MCP server is a trust boundary.** It runs with whatever credentials you
give it, and the data it returns enters the model's context as text that may contain injected
instructions. Prefer read-only scopes, prefer servers you can read the source of, and do not
wire a write-capable server into an unattended loop.

## Prompting, briefly

Most advice reduces to: **say what you actually want, with the context needed to do it.**

```
# weak
make this better

# better
This function is O(n²) because of the nested lookup on line 14.
Rewrite it to be linear, keeping the same signature and behaviour for
empty input. It runs on Python 3.11. Do not add dependencies.
```

Useful habits: give examples of the output shape you want; ask for a plan before an
implementation on anything non-trivial; demand the *simplest* version rather than the most
general; and when a response is wrong, say specifically what is wrong rather than repeating the
request.

Modern models do not need elaborate role-play preambles or threat-laden instructions. Over-
prescriptive prompts written for older models frequently make current ones *worse* — if a prompt
has accumulated a decade of cargo cult, deleting most of it is often an improvement.

## Does it actually help?

Worth measuring honestly, because the subjective sense of speed is unreliable.

Reasonable signals: time from start to merged; defects found in review or production on
AI-authored changes versus others; whether the team can explain code it shipped. Note the
headline risk — **faster authoring with slower review and more defects is a net loss** that feels
like a win.

Where it reliably pays off: unfamiliar languages and APIs, tests for existing code, boilerplate,
explaining legacy code, and first drafts of documentation. Where it reliably does not: anything
where being subtly wrong is expensive and verification is hard.

## Related

- [ai-for-infrastructure.md](ai-for-infrastructure.md) — higher stakes, different guardrails
- [../Containers/docker/dockerfile-best-practices.md](../Containers/docker/dockerfile-best-practices.md) — scanning generated images
- [../Secrets Management/secrets-management-patterns.md](../Secrets%20Management/secrets-management-patterns.md) — what never goes in a prompt
