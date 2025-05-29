using HTTP
using Sockets
using JSON

function handle_request(req)
    if req.method == "GET"
        payload = Dict("status" => "Julia API is live")
        return HTTP.Response(200, JSON.json(payload))
    elseif req.method == "POST"
        body = JSON.parse(String(req.body))
        result = body["x"] + body["y"]  # example logic
        payload = Dict("result" => result)
        return HTTP.Response(200, JSON.json(payload))
    end
end

HTTP.serve(handle_request, Sockets.localhost, 8080)
