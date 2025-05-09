using HTTP
using Sockets
using JSON

function handle_request(req)
    if req.method == "GET"
        return HTTP.Response(200, JSON.json("status" => "Julia API is live"))
    elseif req.method == "POST"
        body = JSON.parse(String(req.body))
        result = body["x"] + body["y"]  # example logic
        return HTTP.Response(200, JSON.json("result" => result))
    end
end

HTTP.serve(handle_request, Sockets.localhost, 8080)
