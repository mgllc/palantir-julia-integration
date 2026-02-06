using HTTP
using Sockets
using JSON

const MAX_BODY_BYTES = 1_024 * 10

function json_response(status::Integer, payload::Dict)
    return HTTP.Response(status, ["Content-Type" => "application/json"], JSON.json(payload))
end

function is_json_content_type(value)
    return !isempty(value) && startswith(lowercase(value), "application/json")
end

function parse_json_body(req)
    content_type = HTTP.header(req, "Content-Type")
    if content_type === nothing || !is_json_content_type(content_type)
        return (nothing, json_response(415, Dict("error" => "Content-Type must be application/json")))
    end

    if length(req.body) > MAX_BODY_BYTES
        return (nothing, json_response(413, Dict("error" => "Payload too large")))
    end

    body = try
        JSON.parse(String(req.body))
    catch
        return (nothing, json_response(400, Dict("error" => "Invalid JSON payload")))
    end

    if !(body isa Dict)
        return (nothing, json_response(422, Dict("error" => "Payload must be a JSON object")))
    end

    return (body, nothing)
end

function handle_add(req)
    body, error_response = parse_json_body(req)
    if error_response !== nothing
        return error_response
    end

    if !haskey(body, "x") || !haskey(body, "y")
        return json_response(422, Dict("error" => "Payload must include numeric fields 'x' and 'y'"))
    end

    if !(body["x"] isa Real) || !(body["y"] isa Real)
        return json_response(422, Dict("error" => "Fields 'x' and 'y' must be numbers"))
    end

    result = body["x"] + body["y"]
    return json_response(200, Dict("result" => result))
end

function handle_ai_echo(req)
    body, error_response = parse_json_body(req)
    if error_response !== nothing
        return error_response
    end

    if !haskey(body, "prompt") || !(body["prompt"] isa AbstractString)
        return json_response(422, Dict("error" => "Payload must include string field 'prompt'"))
    end

    response = "Echo: " * body["prompt"]
    payload = Dict("response" => response, "note" => "AI echo stub; replace with model integration.")
    return json_response(200, payload)
end

function handle_request(req)
    path = HTTP.URI(req.target).path
    if req.method == "GET" && path == "/health"
        return json_response(200, Dict("status" => "Julia API is live"))
    elseif req.method == "POST" && path == "/add"
        return handle_add(req)
    elseif req.method == "POST" && path == "/ai/echo"
        return handle_ai_echo(req)
    elseif req.method in ("GET", "POST")
        return json_response(404, Dict("error" => "Not found"))
    else
        return json_response(405, Dict("error" => "Method not allowed"))
    end
end

HTTP.serve(handle_request, Sockets.localhost, 8080)
