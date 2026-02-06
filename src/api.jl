using HTTP
using Sockets
using JSON
using UUIDs

const MAX_BODY_BYTES = 1_024 * 10

function json_response(status::Integer, payload::Dict; request_id::Union{Nothing, String}=nothing)
    headers = [
        "Content-Type" => "application/json",
        "Cache-Control" => "no-store",
        "X-Content-Type-Options" => "nosniff",
    ]
    if request_id !== nothing
        push!(headers, "X-Request-Id" => request_id)
    end
    return HTTP.Response(status, headers, JSON.json(payload))
end

function is_json_content_type(value)
    return !isempty(value) && startswith(lowercase(value), "application/json")
end

function parse_json_body(req, request_id)
    content_type = HTTP.header(req, "Content-Type")
    if content_type === nothing || !is_json_content_type(content_type)
        return (nothing, json_response(415, Dict("error" => "Content-Type must be application/json"); request_id=request_id))
    end

    if length(req.body) > MAX_BODY_BYTES
        return (nothing, json_response(413, Dict("error" => "Payload too large"); request_id=request_id))
    end

    body = try
        JSON.parse(String(req.body))
    catch
        return (nothing, json_response(400, Dict("error" => "Invalid JSON payload"); request_id=request_id))
    end

    if !(body isa Dict)
        return (nothing, json_response(422, Dict("error" => "Payload must be a JSON object"); request_id=request_id))
    end

    return (body, nothing)
end

function handle_add(req, request_id)
    body, error_response = parse_json_body(req, request_id)
    if error_response !== nothing
        return error_response
    end

    if !haskey(body, "x") || !haskey(body, "y")
        return json_response(422, Dict("error" => "Payload must include numeric fields 'x' and 'y'"); request_id=request_id)
    end

    if !(body["x"] isa Real) || !(body["y"] isa Real)
        return json_response(422, Dict("error" => "Fields 'x' and 'y' must be numbers"); request_id=request_id)
    end

    result = body["x"] + body["y"]
    return json_response(200, Dict("result" => result); request_id=request_id)
end

function handle_ai_echo(req, request_id)
    body, error_response = parse_json_body(req, request_id)
    if error_response !== nothing
        return error_response
    end

    if !haskey(body, "prompt") || !(body["prompt"] isa AbstractString)
        return json_response(422, Dict("error" => "Payload must include string field 'prompt'"); request_id=request_id)
    end

    response = "Echo: " * body["prompt"]
    payload = Dict("response" => response, "note" => "AI echo stub; replace with model integration.")
    return json_response(200, payload; request_id=request_id)
end

function handle_request(req)
    path = HTTP.URI(req.target).path
    request_id = string(uuid4())
    @info "request" method=req.method path=path request_id=request_id
    if req.method == "GET" && path == "/health"
        return json_response(200, Dict("status" => "Julia API is live"); request_id=request_id)
    elseif req.method == "POST" && path == "/add"
        return handle_add(req, request_id)
    elseif req.method == "POST" && path == "/ai/echo"
        return handle_ai_echo(req, request_id)
    elseif req.method in ("GET", "POST")
        return json_response(404, Dict("error" => "Not found"); request_id=request_id)
    else
        return json_response(405, Dict("error" => "Method not allowed"); request_id=request_id)
    end
end

HTTP.serve(handle_request, Sockets.localhost, 8080)
