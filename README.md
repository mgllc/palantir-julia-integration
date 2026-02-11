# Palantir Julia Integration

A minimal Julia HTTP service that demonstrates how to expose small analytics-style endpoints (`/add`, `/ai/echo`) for downstream systems.

## Quick Start

```bash
docker build -t julia-api ./docker
docker run --rm -p 8080:8080 julia-api
```

Then test the endpoints:

```bash
curl http://localhost:8080/health
curl -X POST http://localhost:8080/add -H "Content-Type: application/json" -d '{"x":2,"y":3}'
curl -X POST http://localhost:8080/ai/echo -H "Content-Type: application/json" -d '{"prompt":"hello"}'
```

## Repository Structure

```text
palantir-julia-integration/
├── src/
│   └── api.jl                 # HTTP routes, request validation, JSON responses
├── docker/
│   └── Dockerfile             # Container image build and runtime command
├── notebooks/
│   └── example_bridge.ipynb   # Tiny Python request example
└── Project.toml               # Julia package dependencies
```

## How the API Works (Logical Flow)

1. `HTTP.serve` starts a server on port `8080` and forwards every request to `handle_request`.
2. `handle_request` routes by method + path:
   - `GET /health`
   - `POST /add`
   - `POST /ai/echo`
   - otherwise `404` (`GET`/`POST`) or `405` (other methods)
3. POST handlers call `parse_json_body` to enforce:
   - `Content-Type: application/json` (`415` otherwise)
   - payload size limit (`413` for oversized bodies)
   - valid JSON object payload (`400`/`422` errors)
4. Endpoint-specific validation runs:
   - `/add`: numeric `x` and `y`, returns `{"result": x + y}`
   - `/ai/echo`: string `prompt`, returns a stubbed echo response

This structure centralizes shared validation and keeps each endpoint focused on business logic.

## API Endpoints

### `GET /health`
Returns a simple status payload.

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

- `400` invalid JSON body
- `404` unknown `GET`/`POST` route
- `405` unsupported method
- `413` payload too large
- `415` non-JSON content type
- `422` structurally valid request with invalid/missing fields

## What to Learn Next

1. **HTTP.jl basics**: routing strategies and middleware patterns.
2. **Input validation patterns**: expand current checks into reusable schema-style validation.
3. **Service hardening**: request logging, metrics, auth, and rate-limits.
4. **Foundry integration path**: call this API from Python-based orchestration or containerized jobs.
5. **Testing**: add endpoint tests for happy-path and error-path behavior.
