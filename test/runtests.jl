using Test
using HTTP
using JSON

# Include the API source without starting the server (guarded by PROGRAM_FILE check).
include(joinpath(@__DIR__, "..", "src", "api.jl"))

# Helper: build a minimal POST request with a JSON body.
function make_post(path::String, body::Dict; content_type::String="application/json",
                   api_key::String="", forwarded_for::String="")
    headers = Pair{String,String}["Content-Type" => content_type]
    !isempty(api_key)       && push!(headers, "X-API-Key"       => api_key)
    !isempty(forwarded_for) && push!(headers, "X-Forwarded-For" => forwarded_for)
    return HTTP.Request("POST", path, headers, Vector{UInt8}(JSON.json(body)))
end

# Helper: build a minimal GET request.
function make_get(path::String; api_key::String="", forwarded_for::String="")
    headers = Pair{String,String}[]
    !isempty(api_key)       && push!(headers, "X-API-Key"       => api_key)
    !isempty(forwarded_for) && push!(headers, "X-Forwarded-For" => forwarded_for)
    return HTTP.Request("GET", path, headers, UInt8[])
end

# ──────────────────────────────────────────────────────────────────────────────
@testset "is_json_content_type" begin
    @test is_json_content_type("application/json")           == true
    @test is_json_content_type("Application/JSON")           == true
    @test is_json_content_type("application/json; charset=utf-8") == true
    @test is_json_content_type("text/plain")                 == false
    @test is_json_content_type("")                           == false
end

# ──────────────────────────────────────────────────────────────────────────────
@testset "json_response" begin
    # HTTP.jl canonicalizes header casing (e.g. "X-Correlation-Id"), so look
    # headers up with the case-insensitive HTTP.header() accessor rather than
    # an exact-string Dict/list match.
    resp = json_response(200, Dict("status" => "ok"); correlation_id="test-id")
    @test resp.status == 200
    @test HTTP.header(resp, "Content-Type")           == "application/json"
    @test HTTP.header(resp, "X-Content-Type-Options") == "nosniff"
    @test HTTP.header(resp, "X-Frame-Options")        == "DENY"
    @test HTTP.header(resp, "Cache-Control")          == "no-store"
    @test HTTP.header(resp, "X-Correlation-ID")       == "test-id"
    body = JSON.parse(String(resp.body))
    @test body["status"] == "ok"
end

@testset "json_response without correlation_id" begin
    resp = json_response(404, Dict("error" => "Not found"))
    @test resp.status == 404
    @test HTTP.header(resp, "X-Correlation-ID", "") == ""
end

# ──────────────────────────────────────────────────────────────────────────────
@testset "decide_handler routing" begin
    @test decide_handler("GET",    "/health")  == :health
    @test decide_handler("GET",    "/metrics") == :metrics
    @test decide_handler("GET",    "/metrics/prometheus") == :prometheus
    @test decide_handler("POST",   "/add")     == :add
    @test decide_handler("POST",   "/ai/echo") == :ai_echo
    @test decide_handler("GET",    "/missing") == :not_found
    @test decide_handler("POST",   "/missing") == :not_found
    @test decide_handler("DELETE", "/health")  == :method_not_allowed
    @test decide_handler("PUT",    "/add")     == :method_not_allowed
    @test decide_handler("PATCH",  "/add")     == :method_not_allowed
end

# ──────────────────────────────────────────────────────────────────────────────
@testset "handle_health" begin
    resp = handle_health("cid-health")
    @test resp.status == 200
    body = JSON.parse(String(resp.body))
    @test body["status"] == "Julia API is live"
end

# ──────────────────────────────────────────────────────────────────────────────
@testset "handle_metrics" begin
    resp = handle_metrics("cid-metrics")
    @test resp.status == 200
    body = JSON.parse(String(resp.body))
    @test haskey(body, "rate_limit_clients_tracked")
    @test body["rate_limit_window_seconds"] == RATE_LIMIT_WINDOW
    @test body["rate_limit_max_requests"]   == RATE_LIMIT_COUNT
end

# ──────────────────────────────────────────────────────────────────────────────
@testset "handle_add — happy path" begin
    req  = make_post("/add", Dict("x" => 2, "y" => 3))
    resp = handle_add(req, "cid-add")
    @test resp.status == 200
    body = JSON.parse(String(resp.body))
    @test body["result"] == 5

    # Floating-point operands
    req2  = make_post("/add", Dict("x" => 1.5, "y" => 2.5))
    resp2 = handle_add(req2, "cid-add-float")
    @test resp2.status == 200
    @test JSON.parse(String(resp2.body))["result"] ≈ 4.0
end

@testset "handle_add — missing fields" begin
    req  = make_post("/add", Dict("x" => 1))
    resp = handle_add(req, "cid-add-missing")
    @test resp.status == 422
    body = JSON.parse(String(resp.body))
    @test haskey(body, "error")

    req2  = make_post("/add", Dict("y" => 1))
    resp2 = handle_add(req2, "cid-add-missing-x")
    @test resp2.status == 422
end

@testset "handle_add — non-numeric fields" begin
    req  = make_post("/add", Dict("x" => "a", "y" => 3))
    resp = handle_add(req, "cid-add-nonnum")
    @test resp.status == 422
end

@testset "handle_add — wrong Content-Type" begin
    headers = Pair{String,String}["Content-Type" => "text/plain"]
    req  = HTTP.Request("POST", "/add", headers, Vector{UInt8}("{\"x\":1,\"y\":2}"))
    resp = handle_add(req, "cid-add-ct")
    @test resp.status == 415
end

@testset "handle_add — invalid JSON" begin
    headers = Pair{String,String}["Content-Type" => "application/json"]
    req  = HTTP.Request("POST", "/add", headers, Vector{UInt8}("not-json"))
    resp = handle_add(req, "cid-add-badjson")
    @test resp.status == 400
end

@testset "handle_add — oversized payload" begin
    headers = Pair{String,String}["Content-Type" => "application/json"]
    req  = HTTP.Request("POST", "/add", headers, fill(UInt8('x'), MAX_BODY_BYTES + 1))
    resp = handle_add(req, "cid-add-big")
    @test resp.status == 413
end

# ──────────────────────────────────────────────────────────────────────────────
@testset "handle_ai_echo — happy path (stub, no AI_BASE_URL)" begin
    req  = make_post("/ai/echo", Dict("prompt" => "hello"))
    resp = handle_ai_echo(req, "cid-echo")
    @test resp.status == 200
    body = JSON.parse(String(resp.body))
    @test body["response"] == "Echo: hello"
    @test body["source"] == "stub"
    @test haskey(body, "note")
end

@testset "handle_ai_echo — missing prompt" begin
    req  = make_post("/ai/echo", Dict("text" => "hello"))
    resp = handle_ai_echo(req, "cid-echo-missing")
    @test resp.status == 422
end

@testset "handle_ai_echo — non-string prompt" begin
    req  = make_post("/ai/echo", Dict("prompt" => 42))
    resp = handle_ai_echo(req, "cid-echo-nonstr")
    @test resp.status == 422
end

@testset "handle_ai_echo — wrong Content-Type" begin
    headers = Pair{String,String}["Content-Type" => "text/plain"]
    req  = HTTP.Request("POST", "/ai/echo", headers, Vector{UInt8}(JSON.json(Dict("prompt" => "hi"))))
    resp = handle_ai_echo(req, "cid-echo-ct")
    @test resp.status == 415
end

# ──────────────────────────────────────────────────────────────────────────────
@testset "call_ai_model" begin
    @test call_ai_model("hello") === nothing   # AI_BASE_URL unset by default

    old_url = AI_BASE_URL[]
    try
        # Unreachable endpoint: the HTTP failure must be caught and degrade to
        # `nothing` (falls back to the echo stub) rather than propagating.
        AI_BASE_URL[] = "http://127.0.0.1:1"
        @test call_ai_model("hello") === nothing
    finally
        AI_BASE_URL[] = old_url
    end
end

# ──────────────────────────────────────────────────────────────────────────────
@testset "handle_prometheus" begin
    resp = handle_prometheus("cid-prom")
    @test resp.status == 200
    @test HTTP.header(resp, "Content-Type") == "text/plain; version=0.0.4; charset=utf-8"
    body = String(resp.body)
    @test occursin("julia_api_uptime_seconds", body)
    @test occursin("julia_api_requests_total", body)

    record_response!(200, "/health")
    resp2 = handle_prometheus("cid-prom-2")
    body2 = String(resp2.body)
    @test occursin("julia_api_requests_total{status=\"200\"}", body2)
    @test occursin("julia_api_endpoint_requests_total{endpoint=\"/health\",status=\"200\"}", body2)
end

# ──────────────────────────────────────────────────────────────────────────────
@testset "orient_request — authentication" begin
    old_key = REQUIRED_API_KEY[]
    try
        REQUIRED_API_KEY[] = "secret123"

        # Missing key → 401
        req  = make_get("/health")
        resp = orient_request(req, "cid-auth-missing", "127.0.0.1")
        @test resp !== nothing
        @test resp.status == 401

        # Wrong key → 401
        req2  = make_get("/health"; api_key="wrongkey")
        resp2 = orient_request(req2, "cid-auth-wrong", "127.0.0.2")
        @test resp2 !== nothing
        @test resp2.status == 401

        # Correct key → passes (returns nothing)
        req3  = make_get("/health"; api_key="secret123")
        resp3 = orient_request(req3, "cid-auth-ok", "127.0.0.3")
        @test resp3 === nothing
    finally
        REQUIRED_API_KEY[] = old_key
    end
end

@testset "orient_request — no auth required" begin
    old_key = REQUIRED_API_KEY[]
    try
        REQUIRED_API_KEY[] = ""
        req  = make_get("/health")
        resp = orient_request(req, "cid-noauth", "127.0.1.1")
        @test resp === nothing
    finally
        REQUIRED_API_KEY[] = old_key
    end
end

# ──────────────────────────────────────────────────────────────────────────────
@testset "handle_request — full pipeline GET /health" begin
    old_key = REQUIRED_API_KEY[]
    try
        REQUIRED_API_KEY[] = ""
        req  = make_get("/health"; forwarded_for="10.0.0.1")
        resp = handle_request(req)
        @test resp.status == 200
        @test HTTP.header(resp, "X-Correlation-ID", "") != ""
        body = JSON.parse(String(resp.body))
        @test body["status"] == "Julia API is live"
    finally
        REQUIRED_API_KEY[] = old_key
    end
end

@testset "handle_request — full pipeline POST /add" begin
    old_key = REQUIRED_API_KEY[]
    try
        REQUIRED_API_KEY[] = ""
        req  = make_post("/add", Dict("x" => 10, "y" => 5); forwarded_for="10.0.0.2")
        resp = handle_request(req)
        @test resp.status == 200
        @test JSON.parse(String(resp.body))["result"] == 15
    finally
        REQUIRED_API_KEY[] = old_key
    end
end

@testset "handle_request — full pipeline 404" begin
    old_key = REQUIRED_API_KEY[]
    try
        REQUIRED_API_KEY[] = ""
        req  = make_get("/nonexistent"; forwarded_for="10.0.0.3")
        resp = handle_request(req)
        @test resp.status == 404
    finally
        REQUIRED_API_KEY[] = old_key
    end
end

@testset "handle_request — full pipeline 405" begin
    old_key = REQUIRED_API_KEY[]
    try
        REQUIRED_API_KEY[] = ""
        headers = Pair{String,String}[]
        req  = HTTP.Request("DELETE", "/health", headers, UInt8[])
        resp = handle_request(req)
        @test resp.status == 405
    finally
        REQUIRED_API_KEY[] = old_key
    end
end

@testset "handle_request — auth enforced end-to-end" begin
    old_key = REQUIRED_API_KEY[]
    try
        REQUIRED_API_KEY[] = "mysecret"

        # Request without key is rejected
        req  = make_get("/health"; forwarded_for="10.0.0.4")
        resp = handle_request(req)
        @test resp.status == 401

        # Request with correct key succeeds
        req2  = make_get("/health"; api_key="mysecret", forwarded_for="10.0.0.5")
        resp2 = handle_request(req2)
        @test resp2.status == 200
    finally
        REQUIRED_API_KEY[] = old_key
    end
end
