using HTTP
using JSON
using Dates
using UUIDs

# ─── Configuration ────────────────────────────────────────────────────────────
# All tuneable limits and secrets are read from environment variables so that
# nothing sensitive is baked into source code (principle: no hard-coded secrets).

const MAX_BODY_BYTES    = 1_024 * 10   # 10 KB payload cap
const RATE_LIMIT_COUNT  = 60           # max requests per window per client IP
const RATE_LIMIT_WINDOW = 60           # sliding window length in seconds
# When API_KEY is set, every request must carry a matching X-API-Key header.
# Leave unset (or empty) to run without authentication (development only).
const REQUIRED_API_KEY  = get(ENV, "API_KEY", "")

# ─── In-memory rate-limit store ───────────────────────────────────────────────
# Maps client IP → sorted list of request timestamps within the current window.
const _rate_store = Dict{String, Vector{Float64}}()
const _rate_lock  = ReentrantLock()

# ─── Structured audit logger ──────────────────────────────────────────────────
# Emits one JSON line per event so that log aggregators (Splunk, Elasticsearch,
# etc.) can ingest and query without parsing free-form text (principle: auditable
# machine-readable logs).
#
# Parameters:
#   correlation_id – UUID that ties all log entries for a single request together.
#   phase          – OODA phase: "OBSERVE", "ORIENT", or "ACT".
#   method         – HTTP method (e.g. "GET", "POST").
#   path           – Request path (e.g. "/add").
#   status         – HTTP status code; 0 while the response has not yet been sent.
#   client_ip      – Caller IP extracted from X-Forwarded-For, or "unknown".
#   detail         – Human-readable event description for the log record.
function audit_log(; correlation_id::AbstractString, phase::AbstractString,
                     method::AbstractString="", path::AbstractString="", status::Int=0,
                     client_ip::AbstractString="", detail::AbstractString="")
    # `time()` is Unix epoch seconds (always UTC); unix2datetime converts it to a
    # UTC DateTime without needing the separate TimeZones.jl package.
    ts = Dates.format(Dates.unix2datetime(time()), "yyyy-mm-ddTHH:MM:SS") * "Z"
    println(JSON.json(Dict(
        "timestamp"      => ts,
        "correlation_id" => correlation_id,
        "phase"          => phase,
        "method"         => method,
        "path"           => path,
        "status"         => status,
        "client_ip"      => client_ip,
        "detail"         => detail,
    )))
    # stdout is fully buffered (not line-buffered) once redirected to a pipe,
    # as it always is under Docker — without this, audit entries can sit
    # unflushed indefinitely on a low-traffic server.
    flush(stdout)
end

# ─── Response builder with hardened security headers ─────────────────────────
# All responses include defensive HTTP headers regardless of content to harden
# the service at the transport layer (principle: security by default).
function json_response(status::Integer, payload::Dict; correlation_id::AbstractString="")
    headers = [
        "Content-Type"              => "application/json",
        "X-Content-Type-Options"    => "nosniff",
        "X-Frame-Options"           => "DENY",
        "Cache-Control"             => "no-store",
        "Strict-Transport-Security" => "max-age=31536000; includeSubDomains",
    ]
    if !isempty(correlation_id)
        push!(headers, "X-Correlation-ID" => correlation_id)
    end
    return HTTP.Response(status, headers, JSON.json(payload))
end

function is_json_content_type(value)
    return !isempty(value) && startswith(lowercase(value), "application/json")
end

function parse_json_body(req; correlation_id::AbstractString="")
    content_type = HTTP.header(req, "Content-Type")
    if content_type === nothing || !is_json_content_type(content_type)
        return (nothing, json_response(415, Dict("error" => "Content-Type must be application/json");
                                       correlation_id=correlation_id))
    end

    if length(req.body) > MAX_BODY_BYTES
        return (nothing, json_response(413, Dict("error" => "Payload too large");
                                       correlation_id=correlation_id))
    end

    body = try
        JSON.parse(String(req.body))
    catch
        return (nothing, json_response(400, Dict("error" => "Invalid JSON payload");
                                       correlation_id=correlation_id))
    end

    if !(body isa Dict)
        return (nothing, json_response(422, Dict("error" => "Payload must be a JSON object");
                                       correlation_id=correlation_id))
    end

    return (body, nothing)
end

# ══════════════════════════════════════════════════════════════════════════════
# OODA LOOP — request processing follows the four phases explicitly so that
# every security and governance control has a clear, auditable home.
# ══════════════════════════════════════════════════════════════════════════════

# ─── Phase 1: OBSERVE ─────────────────────────────────────────────────────────
# Collect raw signal from the inbound request and assign a unique correlation ID
# that threads through every subsequent log entry for full traceability
# (principle: accountability and traceability).
#
# Returns a tuple (correlation_id, client_ip, method, path).
function observe_request(req)
    correlation_id = string(UUIDs.uuid4())
    client_ip = something(HTTP.header(req, "X-Forwarded-For", ""), "")
    if isempty(client_ip)
        client_ip = "unknown"
    end
    method = req.method
    path   = HTTP.URI(req.target).path
    audit_log(
        correlation_id = correlation_id,
        phase          = "OBSERVE",
        method         = method,
        path           = path,
        client_ip      = client_ip,
        detail         = "request received",
    )
    return (correlation_id, client_ip, method, path)
end

# ─── Phase 2: ORIENT ──────────────────────────────────────────────────────────
# Analyse the request context: authenticate the caller and enforce rate limits
# before any business logic executes (principle: zero-trust, deny-by-default).
#
# Returns `nothing` on success, or an HTTP.Response to short-circuit the
# pipeline on authentication failure (401) or rate-limit violation (429).
function orient_request(req, correlation_id::AbstractString, client_ip::AbstractString)
    # Authentication — enforced when API_KEY environment variable is set.
    if !isempty(REQUIRED_API_KEY)
        api_key = something(HTTP.header(req, "X-API-Key", ""), "")
        if api_key != REQUIRED_API_KEY
            audit_log(
                correlation_id = correlation_id,
                phase          = "ORIENT",
                client_ip      = client_ip,
                status         = 401,
                detail         = "invalid or missing API key",
            )
            return json_response(401, Dict("error" => "Unauthorized");
                                 correlation_id=correlation_id)
        end
    end

    # Per-IP rate limiting — sliding window (principle: availability protection).
    now_ts  = time()
    allowed = lock(_rate_lock) do
        timestamps = get!(_rate_store, client_ip, Float64[])
        filter!(t -> now_ts - t < RATE_LIMIT_WINDOW, timestamps)
        if length(timestamps) >= RATE_LIMIT_COUNT
            return false
        end
        push!(timestamps, now_ts)
        return true
    end

    if !allowed
        audit_log(
            correlation_id = correlation_id,
            phase          = "ORIENT",
            client_ip      = client_ip,
            status         = 429,
            detail         = "rate limit exceeded",
        )
        return json_response(429, Dict("error" => "Too many requests");
                             correlation_id=correlation_id)
    end

    return nothing
end

# ─── Phase 3: DECIDE ──────────────────────────────────────────────────────────
# Select the appropriate handler based solely on method and path.  All routing
# logic lives here, keeping handlers free of routing concerns.
#
# Returns a Symbol identifying the handler:
#   :health, :metrics, :add, :ai_echo, :not_found, or :method_not_allowed.
function decide_handler(method::AbstractString, path::AbstractString)
    if method == "GET" && path == "/health"
        return :health
    elseif method == "GET" && path == "/metrics"
        return :metrics
    elseif method == "POST" && path == "/add"
        return :add
    elseif method == "POST" && path == "/ai/echo"
        return :ai_echo
    elseif method in ("GET", "POST")
        return :not_found
    else
        return :method_not_allowed
    end
end

# ─── Phase 4: ACT — individual handlers ───────────────────────────────────────
# Execute the decided action.  Each handler is responsible only for its own
# business logic; cross-cutting concerns (headers, logging) are handled above.

function handle_health(correlation_id::AbstractString)
    return json_response(200, Dict("status" => "Julia API is live");
                         correlation_id=correlation_id)
end

# Expose lightweight telemetry so operators can observe service health without
# needing external instrumentation (principle: operational visibility).
function handle_metrics(correlation_id::AbstractString)
    clients_tracked = lock(_rate_lock) do
        length(_rate_store)
    end
    return json_response(200, Dict(
        "rate_limit_clients_tracked" => clients_tracked,
        "rate_limit_window_seconds"  => RATE_LIMIT_WINDOW,
        "rate_limit_max_requests"    => RATE_LIMIT_COUNT,
    ); correlation_id=correlation_id)
end

function handle_add(req, correlation_id::AbstractString)
    body, err = parse_json_body(req; correlation_id=correlation_id)
    if err !== nothing
        return err
    end

    if !haskey(body, "x") || !haskey(body, "y")
        return json_response(422, Dict("error" => "Payload must include numeric fields 'x' and 'y'");
                             correlation_id=correlation_id)
    end

    if !(body["x"] isa Real) || !(body["y"] isa Real)
        return json_response(422, Dict("error" => "Fields 'x' and 'y' must be numbers");
                             correlation_id=correlation_id)
    end

    result = body["x"] + body["y"]
    return json_response(200, Dict("result" => result); correlation_id=correlation_id)
end

function handle_ai_echo(req, correlation_id::AbstractString)
    body, err = parse_json_body(req; correlation_id=correlation_id)
    if err !== nothing
        return err
    end

    if !haskey(body, "prompt") || !(body["prompt"] isa AbstractString)
        return json_response(422, Dict("error" => "Payload must include string field 'prompt'");
                             correlation_id=correlation_id)
    end

    response = "Echo: " * body["prompt"]
    payload = Dict("response" => response, "note" => "AI echo stub; replace with model integration.")
    return json_response(200, payload; correlation_id=correlation_id)
end

# ─── Top-level handler: wires all OODA phases together ────────────────────────
# Wrapped so an unhandled exception is logged with its full backtrace instead
# of surfacing as an opaque 500 with no trace of what happened.
function handle_request(req)
    try
        return handle_request_inner(req)
    catch e
        Base.showerror(stderr, e, catch_backtrace())
        println(stderr)
        flush(stderr)
        return HTTP.Response(500, "Internal Server Error")
    end
end

function handle_request_inner(req)
    # Phase 1 — Observe
    correlation_id, client_ip, method, path = observe_request(req)

    # Phase 2 — Orient (authentication + rate limiting)
    orient_err = orient_request(req, correlation_id, client_ip)
    if orient_err !== nothing
        return orient_err
    end

    # Phase 3 — Decide
    handler = decide_handler(method, path)

    # Phase 4 — Act
    response = if handler == :health
        handle_health(correlation_id)
    elseif handler == :metrics
        handle_metrics(correlation_id)
    elseif handler == :add
        handle_add(req, correlation_id)
    elseif handler == :ai_echo
        handle_ai_echo(req, correlation_id)
    elseif handler == :not_found
        json_response(404, Dict("error" => "Not found"); correlation_id=correlation_id)
    else
        json_response(405, Dict("error" => "Method not allowed"); correlation_id=correlation_id)
    end

    audit_log(
        correlation_id = correlation_id,
        phase          = "ACT",
        method         = method,
        path           = path,
        status         = response.status,
        client_ip      = client_ip,
        detail         = "response dispatched",
    )

    return response
end

HTTP.serve(handle_request, "0.0.0.0", 8080)
