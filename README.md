# Palantir Julia Integration

A minimal Julia HTTP service that demonstrates how to expose small analytics-style endpoints (`/add`, `/ai/echo`) for downstream systems, built around a defense-in-depth security posture and an **OODA Loop** request-processing model.

## Quick Start

```bash
docker build -t julia-api ./docker
docker run --rm -p 8080:8080 julia-api
```

With authentication enabled:

```bash
docker run --rm -p 8080:8080 -e API_KEY=mysecret julia-api
```

Then test the endpoints:

```bash
curl http://localhost:8080/health
curl http://localhost:8080/metrics
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

## Repository Structure

```text
palantir-julia-integration/
├── src/
│   └── api.jl                 # HTTP routes, OODA phases, security controls
├── docker/
│   └── Dockerfile             # Container image; API_KEY injected at runtime
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

Response:

```json
{"response": "Echo: Hello", "note": "AI echo stub; replace with model integration."}
```

## Error Behavior

| Status | Cause |
|--------|-------|
| `400`  | Invalid JSON body |
| `401`  | Missing or incorrect `X-API-Key` (when `API_KEY` env var is set) |
| `404`  | Unknown `GET` / `POST` route |
| `405`  | Unsupported HTTP method |
| `413`  | Payload exceeds 10 KB |
| `415`  | Non-JSON `Content-Type` |
| `422`  | Structurally valid request with invalid or missing fields |
| `429`  | Rate limit exceeded (60 requests per 60-second window per IP) |

## Audit Log Format

Each log line is a single JSON object written to stdout:

```json
{
  "timestamp":      "2024-01-15T12:34:56Z",
  "correlation_id": "550e8400-e29b-41d4-a716-446655440000",
  "phase":          "OBSERVE",
  "method":         "POST",
  "path":           "/add",
  "status":         0,
  "client_ip":      "10.0.0.1",
  "detail":         "request received"
}
```

The `correlation_id` links the `OBSERVE`, `ORIENT`, and `ACT` entries for each request.

## What to Learn Next

1. **HTTP.jl basics**: routing strategies and middleware patterns.
2. **Input validation patterns**: expand current checks into reusable schema-style validation.
3. **Service hardening**: persistent metrics store, distributed rate limiting (Redis), mTLS.
4. **Foundry integration path**: call this API from Python-based orchestration or containerized jobs.
5. **Testing**: add endpoint tests for happy-path and error-path behavior using `HTTP.jl` test client.
