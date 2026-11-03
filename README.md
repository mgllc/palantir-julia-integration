# Palantir Julia Integration

A minimal Julia HTTP service that demonstrates how to expose small analytics-style endpoints (`/add`, `/ai/echo`) for downstream systems, built around a defense-in-depth security posture and an **OODA Loop** request-processing model.

## Quick Start

```bash
docker build -t julia-api -f docker/Dockerfile .
docker run --rm -p 8080:8080 julia-api
```

Or via Compose, which also wires up a Docker-native health check and auto-restart:

```bash
docker compose up --build
```

With authentication enabled:

```bash
docker run --rm -p 8080:8080 -e API_KEY=mysecret julia-api
```

Then test the endpoints:

```bash
curl http://localhost:8080/health
curl http://localhost:8080/metrics
curl http://localhost:8080/metrics/prometheus
curl -X POST http://localhost:8080/add \
     -H "Content-Type: application/json" \
     -d '{"x":2,"y":3}'
curl -X POST http://localhost:8080/ai/echo \
     -H "Content-Type: application/json" \
     -d '{"prompt":"hello"}'

# With authentication:
curl -X POST http://localhost:8080/add \
     -H "Content-Type: application/json" \
     -H "X-API-Key: mysecret" \
     -d '{"x":2,"y":3}'
```

## Configuration

Every tuneable value is read from an environment variable at startup — nothing
requires a code change or rebuild:

| Variable | Default | Purpose |
|----------|---------|---------|
| `API_HOST` | `0.0.0.0` | Bind address |
| `API_PORT` | `8080` | Bind port |
| `API_KEY` | *(unset)* | When set, requires a matching `X-API-Key` header on every request |
| `MAX_BODY_BYTES` | `10240` | Request body size cap |
| `RATE_LIMIT_WINDOW` | `60` | Rate-limit sliding window, seconds |
| `RATE_LIMIT_MAX_REQ` | `60` | Max requests per client IP per window |
| `AI_BASE_URL` | *(unset)* | OpenAI-compatible chat-completions base URL; unset = echo stub |
| `AI_API_KEY` | *(unset)* | Bearer token for the AI provider, if it requires one |
| `AI_MODEL` | *(unset)* | Explicit fixed model override; takes precedence over automatic routing |
| `AI_TIMEOUT_S` | `30` | AI provider request timeout, seconds |
| `AI_DEFAULT_MODEL` | *(unset)* | Conservative model for missing, unknown, or untrusted task metadata |
| `AI_ALLOWED_MODELS` | `AI_DEFAULT_MODEL` | Comma-separated model IDs allowed for automatic routing |
| `AI_TASK_MODELS` | `{}` | JSON object mapping task identifiers to allowed model IDs |
| `AI_TRUST_TASK_METADATA` | `false` | Honor `task_type` only when true and the caller supplies the configured `API_KEY` |
| `AI_MAX_PROMPT_BYTES` | `10240` | UTF-8 prompt byte cap, 1–1048576; HTTP body cap also applies |
| `AI_MAX_OUTPUT_TOKENS` | `512` | Output token cap, 1–4096, sent on every provider request |
| `AI_OUTPUT_TOKEN_PARAMETER` | `max_tokens` | Provider-supported cap field: `max_tokens` or `max_completion_tokens` |
| `AI_SERVICE_TIER` | *(unset)* | Optional `default` requests standard processing on providers supporting OpenAI's `service_tier`; unset omits the field |

### Automatic task-based model selection

Routing is applied to the actual outgoing chat-completions request. Configure
model IDs available at your existing `AI_BASE_URL`; the service does not choose
a provider, discover available models, infer prices, or rank model quality.
The names below are placeholders to replace with deployment-approved IDs:

```bash
export AI_DEFAULT_MODEL='approved-balanced-model'
export AI_ALLOWED_MODELS='approved-economy-model,approved-balanced-model'
export AI_TASK_MODELS='{"extract":"approved-economy-model","classify":"approved-economy-model","summarize":"approved-economy-model","code":"approved-balanced-model","analyze":"approved-balanced-model","research":"approved-balanced-model"}'
export AI_TRUST_TASK_METADATA=true
# Set API_KEY and existing AI_BASE_URL / AI_API_KEY through your secret/config system.
# Leave AI_MODEL unset to allow routing; a nonempty AI_MODEL pins all tasks.
```

An authenticated orchestrator can send `{"prompt":"...","task_type":"summarize"}`.
It must derive `task_type` from trusted workflow metadata, not copy instructions
from retrieved documents or prompt text. Enable metadata trust only for a
service whose API key is held by trusted orchestration code. No-auth development
mode and the default trust setting ignore task metadata for model selection.
Missing and unknown task types use `AI_DEFAULT_MODEL`; malformed task metadata
returns `422`. Prompt keywords and body fields such as `model` and `base_url`
never change routing. Any `complex` route must be explicitly configured and
authorized by that orchestrator; the service never escalates based on failure
or content.

The startup policy rejects routes outside the allowlist and routes without a
default. `AI_MODEL` remains a separately approved deployment override and does
not need an automatic-routing allowlist entry. The former implicit
`gpt-3.5-turbo` default is removed: set `AI_MODEL` explicitly to preserve a fixed
deployment, or configure `AI_DEFAULT_MODEL` for routing. With neither set, the
endpoint returns its existing echo stub without contacting a provider.

All routes share the same endpoint, credential, and deployment data boundary.
The request is made once; redirects and retries are disabled, and provider
errors retain the existing `source: "stub"` response instead of trying another
model or provider. Successful responses report the selected `model` and
`routing_reason` (`task_route`, `default`, or `explicit_override`). A stub is
not a successful model answer; callers should check `source`.

Choose a token-cap parameter supported by **every** routed model on the
configured provider. [OpenAI's Chat Completions reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
documents `max_completion_tokens` as the current cap, including reasoning
tokens; legacy `max_tokens` remains the compatibility default here. Byte/token
caps bound request size and requested output, not dollar cost. Costs and model
availability remain unknown until verified for your account and deployment.

For OpenAI, set `AI_SERVICE_TIER=default` to request standard pricing and
performance for the selected model. Unset preserves compatibility by omitting
the field; OpenAI then uses its `auto` behavior and project configuration, which
can select a premium tier. Other providers may reject `service_tier`, so only
enable it after verifying support. The only accepted nonempty value is
`default`; HTTP request bodies cannot override it. This setting applies equally
to automatic routes and fixed `AI_MODEL` overrides. It requests a processing
tier, not a dollar spending limit or a guarantee about an arbitrary provider.

Run `julia --project=. test/runtests.jl` to exercise policy validation and a
loopback HTTP provider that captures actual model IDs, token caps, and request
paths. Tests clear inherited provider settings and make no paid model calls.
They do not validate live provider permissions, quality, pricing, or support
for the selected models and token-cap field.

## Repository Structure

```text
palantir-julia-integration/
├── src/
│   └── api.jl                 # HTTP routes, OODA phases, security controls
├── docker/
│   └── Dockerfile             # Container image; env-var config, HEALTHCHECK
├── docker-compose.yml         # One-command local run with health check + auto-restart
├── test/
│   └── runtests.jl            # Unit tests — handlers, routing, auth, full pipeline
├── notebooks/
│   └── example_bridge.ipynb   # Python request examples including auth and metrics
└── Project.toml               # Julia package dependencies
```

## Security Principles Applied

A defense-in-depth mindset guides every design decision in this service: treat
every input as hostile, log everything, and fail closed.

| Principle | Implementation |
|-----------|---------------|
| **No hard-coded secrets** | `API_KEY` is read from an environment variable; absent = auth disabled (dev mode only). |
| **Deny-by-default** | When `API_KEY` is set, every request without a valid `X-API-Key` header is rejected with `401`. |
| **Availability protection** | Per-IP sliding-window rate limiting (60 req / 60 s) with a `429` response. |
| **Security headers** | Every response carries `X-Content-Type-Options`, `X-Frame-Options`, `Cache-Control: no-store`, and `Strict-Transport-Security`. |
| **Accountability & traceability** | A UUID correlation ID is generated per request, threaded through all log entries, and returned in `X-Correlation-ID`. |
| **Machine-readable audit logs** | Every phase emits a structured JSON line to stdout for ingestion by log aggregators. |
| **Operational visibility** | A `GET /metrics` endpoint exposes live rate-limit telemetry without external tooling. |
| **Input validation** | Content-Type enforcement, payload size cap, JSON schema checks on every endpoint. |

## OODA Loop — Request Processing Model

The service processes every inbound request through the four OODA phases:

```
┌──────────────────────────────────────────────────────────────┐
│  OBSERVE  →  ORIENT  →  DECIDE  →  ACT                       │
└──────────────────────────────────────────────────────────────┘
```

### OBSERVE (`observe_request`)
Collects raw signal from the request:
- Assigns a unique UUID **correlation ID** for end-to-end traceability.
- Extracts client IP from `X-Forwarded-For` (or marks as `unknown`).
- Emits an `OBSERVE` audit log entry (timestamp, method, path, IP).

### ORIENT (`orient_request`)
Analyses and contextualises the request:
- **Authentication**: validates `X-API-Key` against the `API_KEY` environment variable when set.
- **Rate limiting**: enforces a per-IP sliding-window limit; evicts expired timestamps, counts active ones, rejects with `429` if over threshold.
- Emits `ORIENT` audit entries for all rejected requests.

### DECIDE (`decide_handler`)
Selects the appropriate handler purely from method + path:
- `GET /health` → `:health`
- `GET /metrics` → `:metrics`
- `GET /metrics/prometheus` → `:prometheus`
- `POST /add` → `:add`
- `POST /ai/echo` → `:ai_echo`
- Other `GET`/`POST` → `:not_found` (404)
- Any other method → `:method_not_allowed` (405)

### ACT (handler functions + `handle_request`)
Executes the chosen action:
- Runs endpoint-specific validation and business logic.
- Builds the response with hardened security headers and the correlation ID.
- Emits an `ACT` audit log entry with the final HTTP status code.

## API Endpoints

### `GET /health`
Returns service liveness status.

```json
{"status": "Julia API is live"}
```

### `GET /metrics`
Returns live rate-limit telemetry.

```json
{
  "rate_limit_clients_tracked": 3,
  "rate_limit_window_seconds": 60,
  "rate_limit_max_requests": 60
}
```

### `GET /metrics/prometheus`
Prometheus exposition format (v0.0.4) — point a standard `prometheus.yml` scrape
config or Grafana at this endpoint.

```
# HELP julia_api_uptime_seconds API server uptime in seconds
# TYPE julia_api_uptime_seconds gauge
julia_api_uptime_seconds 42

# HELP julia_api_requests_total Total HTTP requests by status code
# TYPE julia_api_requests_total counter
julia_api_requests_total{status="200"} 17

# HELP julia_api_endpoint_requests_total HTTP requests by endpoint and status code
# TYPE julia_api_endpoint_requests_total counter
julia_api_endpoint_requests_total{endpoint="/health",status="200"} 12
```

### `POST /add`
Request:

```json
{"x": 2, "y": 3}
```

Response:

```json
{"result": 5}
```

### `POST /ai/echo`
Request:

```json
{"prompt": "Hello"}
```

Response — `"source"` tells you whether a real model answered or the request
fell back to the stub (unset `AI_BASE_URL`, no model configured, or the AI provider errored/timed out):

```json
{"response": "Echo: Hello", "note": "AI echo stub; set AI_BASE_URL to enable model integration.", "source": "stub"}
```

```json
{"response": "Hello! How can I help?", "model": "approved-balanced-model", "source": "ai", "routing_reason": "default"}
```

## Error Behavior

| Status | Cause |
|--------|-------|
| `400`  | Invalid JSON body |
| `401`  | Missing or incorrect `X-API-Key` (when `API_KEY` env var is set) |
| `404`  | Unknown `GET` / `POST` route |
| `405`  | Unsupported HTTP method |
| `413`  | Payload exceeds `MAX_BODY_BYTES` or prompt exceeds `AI_MAX_PROMPT_BYTES` |
| `415`  | Non-JSON `Content-Type` |
| `422`  | Structurally valid request with invalid or missing fields |
| `429`  | Rate limit exceeded (60 requests per 60-second window per IP) |

## Audit Log Format

Each log line is a single JSON object written to stdout:

```json
{
  "timestamp":      "2024-01-15T12:34:56Z",
  "correlation_id": "550e8400-e29b-41d4-a716-446655440000",
  "phase":          "ACT",
  "method":         "POST",
  "path":           "/add",
  "status":         200,
  "client_ip":      "10.0.0.1",
  "detail":         "response dispatched",
  "elapsed_ms":     1.23
}
```

The `correlation_id` links the `OBSERVE`, `ORIENT`, and `ACT` entries for each
request; `elapsed_ms` (total handling time) is only present on the `ACT` entry.

## What to Learn Next

1. **Service hardening**: persistent metrics store, distributed rate limiting (Redis), mTLS.
2. **Foundry integration path**: call this API from Python-based orchestration or containerized jobs.
3. **Model evaluation**: measure task quality and actual usage against approved deployment models before changing routing configuration.
