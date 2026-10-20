# DQL examples

All queries assume the default setup: hook spans (`service.name` = `claude-code-desktop`
for the Claude Desktop app Code tab, `claude-code` for the CLI) plus, optionally, Claude
Code's native OTel metrics and logs (`service.name` = `claude-code-desktop` on Claude Code
≥ 2.42 for the Desktop app — verified with Desktop 2.42304 — and `claude-code` on the CLI
and on older builds).

`user.email` is the address entered at install time and is present on every signal. On
native metrics/logs the Anthropic account e-mail is kept as `claude.account_email`.

## Hook spans (always on)

### Usage by developer, split by client (Desktop vs CLI)

```dql
fetch spans, from:now()-24h
| filter in(service.name, {"claude-code", "claude-code-desktop"})
| filter startsWith(span.name, "chat")
| summarize
    Requests      = count(),
    Input_Tokens  = sum(toLong(`gen_ai.usage.input_tokens`)),
    Output_Tokens = sum(toLong(`gen_ai.usage.output_tokens`)),
    Avg_Duration  = avg(duration),
  by: { Developer = `user.email`, Client = service.name }
| sort Input_Tokens desc
```

### Usage by model

```dql
fetch spans, from:now()-24h
| filter in(service.name, {"claude-code", "claude-code-desktop"})
| filter startsWith(span.name, "chat")
| summarize Requests = count(),
            Total_Tokens = sum(toLong(`gen_ai.usage.input_tokens`) + toLong(`gen_ai.usage.output_tokens`)),
            Avg_Duration = avg(duration),
  by: {Model = `gen_ai.request.model`}
| sort Total_Tokens desc
```

### Cost per squad / cost center (custom attributes)

```dql
fetch spans, from:now()-30d
| filter in(service.name, {"claude-code", "claude-code-desktop"})
| filter startsWith(span.name, "chat")
| fieldsAdd inp = toDouble(`gen_ai.usage.input_tokens`), out = toDouble(`gen_ai.usage.output_tokens`)
| fieldsAdd est_cost_usd =
    if(contains(`gen_ai.request.model`, "opus"),   inp * 0.000015  + out * 0.000075,
    else: if(contains(`gen_ai.request.model`, "haiku"), inp * 0.000001 + out * 0.000005,
    else: inp * 0.000003 + out * 0.000015))
| summarize Est_Cost_USD = sum(est_cost_usd), Requests = count(), Developers = countDistinct(`user.email`),
  by: { squad, cost_center }
| sort Est_Cost_USD desc
```

> List prices are approximations for input/output tokens and ignore cache discounts.
> Prefer `gen_ai.usage.cost_usd` (hook) or `cost_usd` on the native `api_request` log
> event when they are present.

### Tool calls (what the agent actually did)

```dql
fetch spans, from:now()-1h
| filter in(service.name, {"claude-code", "claude-code-desktop"})
| filter startsWith(span.name, "claude.tool.")
| summarize Calls = count(), Avg_ms = avg(toDouble(`claude.duration_ms`)),
  by: { Tool = `claude.tool_name`, Developer = `user.email` }
| sort Calls desc
```

### Sessions per day, per client

```dql
fetch spans, from:now()-7d
| filter in(service.name, {"claude-code", "claude-code-desktop"})
| filter isNotNull(`gen_ai.conversation.id`)
| makeTimeseries Sessions = countDistinct(`gen_ai.conversation.id`), by: { service.name }, interval: 1d
```

## Native Claude Code logs (needs the OTel env block / managed settings)

Every API call Claude Code makes becomes a log record with `event.name == "api_request"`
and the attributes `model`, `input_tokens`, `output_tokens`, `cache_read_tokens`,
`cache_creation_tokens`, `cost_usd`, `duration_ms`, `session.id`, `terminal.type`.
Record shape in Grail: `content` is the event name prefixed with `claude_code.`
(`claude_code.api_request`, `claude_code.user_prompt`, `claude_code.tool_result`,
`claude_code.tool_decision`, `claude_code.hook_execution_complete`, …), `event.name` is the
bare name, there is no `log.source`, and the resource attributes (`service.name`,
`service.version`, `user.email`, `squad`, `cost_center`, …) are flattened onto the record.
`service.name` is `claude-code-desktop` for the Desktop app (Claude Code 2.42+) and
`claude-code` for the CLI and for older builds, so every query below accepts both.

If these queries return nothing although the collector log shows `Logs` batches, run the
[health check](#native-logs-health-check) first: the usual cause is that your user cannot
read the `default_logs` bucket, not that the data is missing.

### Tokens and cost per developer and model

```dql
fetch logs, from:now()-24h
| filter in(service.name, {"claude-code", "claude-code-desktop"}) and event.name == "api_request"
| summarize
    Requests        = count(),
    Input_Tokens    = sum(toLong(input_tokens)),
    Output_Tokens   = sum(toLong(output_tokens)),
    Cache_Read      = sum(toLong(cache_read_tokens)),
    Cache_Creation  = sum(toLong(cache_creation_tokens)),
    Cost_USD        = sum(toDouble(cost_usd)),
    Avg_Duration_ms = avg(toDouble(duration_ms)),
  by: { Developer = `user.email`, Model = model }
| sort Cost_USD desc
```

### Daily cost trend per developer

```dql
fetch logs, from:now()-30d
| filter in(service.name, {"claude-code", "claude-code-desktop"}) and event.name == "api_request"
| makeTimeseries Cost_USD = sum(toDouble(cost_usd)), by: { `user.email` }, interval: 1d
```

### Which native sessions came from the Claude Desktop app?

With Claude Code 2.42+ the native records already say so: `service.name` is
`claude-code-desktop` for the Desktop app, so `summarize ..., by: { service.name }` is enough.
Older builds report `claude-code` for both clients and have no entrypoint attribute
(`terminal.type` is `non-interactive` for the Desktop app and for scripted `claude -p` runs
alike). For those, the hook spans do know: join on the session id.

```dql
fetch logs, from:now()-24h
| filter in(service.name, {"claude-code", "claude-code-desktop"}) and event.name == "api_request"
| summarize Cost_USD = sum(toDouble(cost_usd)), Requests = count(), by: { session_id = `session.id`, `user.email` }
| join [
    fetch spans, from:now()-24h
    | filter in(service.name, {"claude-code", "claude-code-desktop"})
    | summarize Client = takeFirst(service.name), by: { session_id = `claude.session_id` }
  ], on: { session_id }, fields: { Client }
| fieldsAdd Client = coalesce(Client, "unknown")
| summarize Cost_USD = sum(Cost_USD), Requests = sum(Requests), by: { `user.email`, Client }
| sort Cost_USD desc
```

### API errors

```dql
fetch logs, from:now()-24h
| filter in(service.name, {"claude-code", "claude-code-desktop"}) and event.name == "api_error"
| summarize Errors = count(), by: { `user.email`, model, error }
| sort Errors desc
```

## Native Claude Code metrics

Counters (delta): `claude_code.token.usage` (dimension `type` = input | output | cacheRead |
cacheCreation, plus `model`), `claude_code.cost.usage` (`model`), `claude_code.session.count`,
`claude_code.lines_of_code.count` (`type` = added | removed), `claude_code.commit.count`,
`claude_code.pull_request.count`, `claude_code.active_time.total`.

> **Developer dimensions (1.0.1+).** Claude Code's datapoints carry only its own dimensions
> (`type`, `model`, `user.id`, `session.id`, …), and Dynatrace does not turn OTLP *resource*
> attributes into dimensions unless they are allow-listed in the tenant, so with 1.0.0
> `timeseries … by: { user.email }` on `claude_code.*` returned `null`. Since 1.0.1 the collector's
> `transform/metric_dimensions` copies `user.email`, `deployment.environment` and every custom
> attribute (`squad`, `cost_center`, `--attr …`) onto each datapoint, so the queries below group
> by developer directly. Machines still running 1.0.0 only show up under `model` / `type` / `user.id`.

```dql
timeseries Tokens = sum(claude_code.token.usage), by: { `user.email`, type }, interval: 1h
```

```dql
timeseries Cost_USD = sum(claude_code.cost.usage), by: { squad, `user.email` }, interval: 1d
```

```dql
timeseries Tokens = sum(claude_code.token.usage), by: { type, model }, interval: 1h
```

```dql
timeseries Cost_USD = sum(claude_code.cost.usage), by: { model }, interval: 1d
```

## Health check: is data arriving?

```dql
fetch spans, from:now()-15m
| filter in(service.name, {"claude-code", "claude-code-desktop"})
| summarize spans = count(), clients = collectDistinct(service.name),
            models = collectDistinct(`gen_ai.request.model`), devs = collectDistinct(`user.email`)
```

<a id="native-logs-health-check"></a>
## Native logs health check: stored, routed, readable?

Native metrics land in `default_metrics`, hook spans in `default_spans`, native logs in
`default_logs` through the `logs:default` OpenPipeline route. The OTLP ingest answers
HTTP 200 with an empty `partialSuccess` even when the querying user has no read access to
that bucket, so an empty `fetch logs` does not mean the data was dropped.

**1. Can you read the bucket the logs go to?** The *has access* column of `default_logs` must
be `true`; the *records* column tells you whether the bucket holds data at all.

```dql
fetch dt.system.buckets
| filter dt.system.table == "logs"
| sort name
```

**2. Where do the logs you *can* read live?** Native records should appear here with
`dt.openpipeline.pipelines = "logs:default"` (or your custom route) once access is granted.

```dql
fetch logs, from:now()-2h
| summarize count(), by: { dt.system.bucket, dt.openpipeline.pipelines, service.name }
| sort `count()` desc
```

**3. Are the native records there?**

```dql
fetch logs, from:now()-1h
| filter in(service.name, {"claude-code", "claude-code-desktop"}) or startsWith(content, "claude_code.")
| summarize records = count(), events = collectDistinct(event.name), sessions = countDistinct(`session.id`),
            devs = collectDistinct(`user.email`), models = collectDistinct(model)
```

If step 1 says `false`, fix it on the tenant side (one of):

- IAM (Account Management → Identity & access → Groups → *group* → Permissions): add the
  built-in policy **Read Logs** scoped to the environment with no boundary, or a custom
  `ALLOW storage:buckets:read WHERE storage:bucket-name = "default_logs";` plus
  `storage:logs:read`. If access stays `false` after that, one of the user's groups carries a
  policy with `DENY storage:buckets:read WHERE storage:bucket-name = "default_logs"` — a DENY
  beats every ALLOW, so remove the user from that group (User management → Edit user) or
  drop the statement. Re-run the bucket query afterwards; the change shows within minutes.
- OpenPipeline → Logs → Routing: rule `matchesValue(service.name, "claude-code*")` to a
  pipeline whose storage stage writes to a bucket those users can read (for example a
  dedicated `claude_code_logs` bucket). Logs then show `dt.system.bucket = "claude_code_logs"`.

Nothing in the collector needs to change: body, `event.name`, timestamp, severity and
attribute-count variants were all accepted and stored identically.

## Evaluation results (dt-evals, optional)

Written by `evals/run-evals.sh` (the `@dynatrace-oss/dt-evals` CLI) as bizevents with
`event.type == "gen_ai.evaluation.result"`: one event per evaluated Claude Code turn and
evaluator. `trace_id` / `span_id` point at the hook's `chat` span, `gen_ai.request.model` is the
**judge** model and `gen_ai.evaluation.input.request_model` the Claude model that answered.
Drift results (`--metric drift`) use the same event type with `gen_ai.evaluation.type == "drift"`.

### Score and fail count per evaluator

```dql
fetch bizevents, from:now()-7d
| filter event.type == "gen_ai.evaluation.result"
| summarize turns = countDistinct(trace_id), avg_score = avg(gen_ai.evaluation.score.value),
            fails = countIf(gen_ai.evaluation.score.label == "fail"), by: { gen_ai.evaluation.name }
| fieldsAdd fail_pct = if(turns > 0, 100.0 * fails / turns, else: 0)
| sort fails desc
```

### Runs (what each `run-evals.sh run` produced)

```dql
fetch bizevents, from:now()-30d
| filter event.type == "gen_ai.evaluation.result"
| summarize started = min(timestamp), evaluators = countDistinct(gen_ai.evaluation.name),
            turns = countDistinct(trace_id), events = count(),
            fails = countIf(gen_ai.evaluation.score.label == "fail"),
            judge = takeFirst(gen_ai.request.model), by: { dt.eval.run_id }
| sort started desc
```

### Latest fails with the judge's explanation

```dql
fetch bizevents, from:now()-7d
| filter event.type == "gen_ai.evaluation.result" and gen_ai.evaluation.score.label == "fail"
| fields timestamp, gen_ai.evaluation.name, score = gen_ai.evaluation.score.value,
         gen_ai.evaluation.explanation, model = gen_ai.evaluation.input.request_model, trace_id, span_id
| sort timestamp desc
| limit 20
```

### Fails per developer, squad and client (join with the hook spans)

The result events carry no `user.email`; the hook span of the same trace does.

```dql
fetch bizevents, from:now()-7d
| filter event.type == "gen_ai.evaluation.result" and gen_ai.evaluation.score.label == "fail"
| join [
    fetch spans, from:now()-7d
    | filter gen_ai.operation.name == "chat" and in(service.name, {"claude-code", "claude-code-desktop"})
    | fieldsAdd trace_id = toString(trace.id)
    | summarize Developer = takeFirst(`user.email`), Squad = takeFirst(squad), Client = takeFirst(service.name), by: { trace_id }
  ], on: { trace_id }, fields: { Developer, Squad, Client }
| summarize fails = count(), by: { Developer, Squad, Client, gen_ai.evaluation.name }
| sort fails desc
```

### Coverage: how many captured turns were ever evaluated?

```dql
fetch spans, from:now()-7d
| filter gen_ai.operation.name == "chat" and in(service.name, {"claude-code", "claude-code-desktop"})
| fieldsAdd trace_id = toString(trace.id), has_prompt = isNotNull(gen_ai.prompt.0.content)
| summarize turns = count(), with_prompt = countIf(has_prompt), by: { trace_id }
| join [
    fetch bizevents, from:now()-7d
    | filter event.type == "gen_ai.evaluation.result"
    | summarize evaluated = count(), by: { trace_id }
  ], on: { trace_id }, fields: { evaluated }, kind: leftOuter
| summarize turns = count(), with_prompt = countIf(with_prompt > 0), evaluated = countIf(isNotNull(evaluated))
```

`with_prompt` is 0 while prompt capture is off; the evaluators then have nothing to score.
