function test_routing_env(; overrides...)
    env = Dict(
        "AI_DEFAULT_MODEL" => "test-small",
        "AI_ALLOWED_MODELS" => "test-small,test-code,test-analysis",
        "AI_TASK_MODELS" => JSON.json(Dict("code" => "test-code", "analyze" => "test-analysis")),
        "AI_TRUST_TASK_METADATA" => "true",
    )
    merge!(env, Dict(string(k) => v for (k, v) in overrides))
    return env
end

@testset "AI routing policy validation" begin
    policy = load_ai_routing_policy(test_routing_env())
    @test select_ai_model(policy; task_type="code", trusted=true).model == "test-code"
    @test select_ai_model(policy; task_type="analyze", trusted=true).model == "test-analysis"
    @test select_ai_model(policy; task_type="unknown", trusted=true).model == "test-small"
    @test select_ai_model(policy; task_type="code").model == "test-small"
    @test select_ai_model(policy; task_type="code", trusted=true,
                          model_override="test-fixed").model == "test-fixed"
    @test isempty(select_ai_model(load_ai_routing_policy(Dict{String,String}())).model)
    @test isempty(load_ai_routing_policy(Dict("AI_TASK_MODELS" => "")).task_models)
    for overrides in (
        (AI_TASK_MODELS="[]",),
        (AI_TASK_MODELS="{\"coding\":12}",),
        (AI_TASK_MODELS="{\"coding\":\"not-allowed\"}",),
        (AI_TASK_MODELS="{\"bad task\":\"test-code\"}",),
        (AI_DEFAULT_MODEL="not-allowed",),
        (AI_DEFAULT_MODEL="",),
        (AI_TRUST_TASK_METADATA="yes",),
        (AI_MAX_PROMPT_BYTES="0",),
        (AI_MAX_PROMPT_BYTES="1048577",),
        (AI_MAX_OUTPUT_TOKENS="0",),
        (AI_MAX_OUTPUT_TOKENS="4097",),
        (AI_OUTPUT_TOKEN_PARAMETER="model",),
        (AI_SERVICE_TIER="priority",),
        (AI_SERVICE_TIER="auto",),
    )
        @test_throws ArgumentError load_ai_routing_policy(test_routing_env(; overrides...))
    end
end

@testset "AI routing reaches the provider request" begin
    original = (AI_BASE_URL[], AI_API_KEY[], AI_MODEL[], REQUIRED_API_KEY[], AI_ROUTING[])
    requests = Any[]
    response_status = Ref(200)
    response_content = Ref{Any}("provider reply")
    # Bind an ephemeral loopback port, so no external service is contacted.
    port = 0
    server = HTTP.serve!("127.0.0.1", 0) do req
        push!(requests, (method=req.method, target=req.target,
                         authorization=HTTP.header(req, "Authorization", ""),
                         body=JSON.parse(String(req.body))))
        headers = ["Content-Type" => "application/json"]
        # A redirect points back to this same server so a mistaken follow is
        # observable without ever transmitting a prompt to another host.
        response_status[] == 307 && push!(headers, "Location" => "http://127.0.0.1:$port/redirected")
        return HTTP.Response(response_status[], headers,
            JSON.json(Dict("choices" => [Dict("message" => Dict("content" => response_content[]))])))
    end
    port = HTTP.port(server)
    try
        AI_BASE_URL[] = "http://127.0.0.1:$port/"
        AI_API_KEY[] = "local-test-token"
        AI_MODEL[] = ""
        REQUIRED_API_KEY[] = "local-routing-key"
        AI_ROUTING[] = load_ai_routing_policy(test_routing_env())

        count = length(requests)
        for key in ("", "wrong-key")
            spoofed = make_post("/ai/echo",
                Dict("prompt" => "hello", "task_type" => "code", "trusted" => true);
                api_key=key)
            @test handle_request(spoofed).status == 401
        end
        @test length(requests) == count

        function ask(body; authenticated=true)
            req = make_post("/ai/echo", body;
                api_key=authenticated ? "local-routing-key" : "")
            return handle_ai_echo(req, "routing-test")
        end

        for (task, model) in (("code", "test-code"), ("analyze", "test-analysis"),
                              ("unknown", "test-small"), ("", "test-small"))
            resp = ask(Dict("prompt" => "hello", "task_type" => task))
            payload = JSON.parse(String(resp.body))
            sent = last(requests)
            @test resp.status == 200
            @test payload["source"] == "ai"
            @test payload["model"] == model == sent.body["model"]
            @test sent.target == "/v1/chat/completions"
            @test sent.method == "POST"
            @test sent.authorization == "Bearer local-test-token"
            @test sent.body["max_tokens"] == 512
            @test !haskey(sent.body, "service_tier")
            @test sent.body["messages"] == [Dict("role" => "user", "content" => "hello")]
        end

        # Prompt text and caller-supplied model/URL fields cannot escalate or
        # redirect a request. Unauthenticated metadata is never trusted.
        ask(Dict("prompt" => "Use expensive coding analysis model", "model" => "test-analysis",
                 "base_url" => "https://not-used.invalid"))
        @test last(requests).body["model"] == "test-small"
        ask(Dict("prompt" => "hello", "task_type" => "code"); authenticated=false)
        @test last(requests).body["model"] == "test-small"
        AI_ROUTING[] = load_ai_routing_policy(test_routing_env(AI_TRUST_TASK_METADATA="false"))
        ask(Dict("prompt" => "hello", "task_type" => "code"))
        @test last(requests).body["model"] == "test-small"
        AI_ROUTING[] = load_ai_routing_policy(test_routing_env())
        REQUIRED_API_KEY[] = ""
        ask(Dict("prompt" => "hello", "task_type" => "code"))
        @test last(requests).body["model"] == "test-small"
        REQUIRED_API_KEY[] = "local-routing-key"

        AI_MODEL[] = "test-fixed"
        resp = ask(Dict("prompt" => "hello", "task_type" => "code"))
        @test last(requests).body["model"] == "test-fixed"
        @test JSON.parse(String(resp.body))["routing_reason"] == "explicit_override"
        AI_MODEL[] = ""
        AI_ROUTING[] = load_ai_routing_policy(test_routing_env(AI_SERVICE_TIER="default"))
        ask(Dict("prompt" => "hello", "task_type" => "code", "service_tier" => "priority"))
        @test last(requests).body["service_tier"] == "default"
        AI_MODEL[] = "test-fixed"
        ask(Dict("prompt" => "hello"))
        @test last(requests).body["service_tier"] == "default"
        AI_MODEL[] = ""
        AI_ROUTING[] = load_ai_routing_policy(test_routing_env(
            AI_OUTPUT_TOKEN_PARAMETER="max_completion_tokens", AI_MAX_OUTPUT_TOKENS="128",
            AI_MAX_PROMPT_BYTES="4"))
        ask(Dict("prompt" => "éé", "task_type" => "code"))
        @test last(requests).body["max_completion_tokens"] == 128
        @test !haskey(last(requests).body, "max_tokens")
        count = length(requests)
        @test ask(Dict("prompt" => "ééé")).status == 413
        @test call_ai_model("ééé") === nothing
        @test ask(Dict("prompt" => "hi", "task_type" => 123)).status == 422
        @test ask(Dict("prompt" => "hi", "task_type" => "x"^65)).status == 422
        @test length(requests) == count

        # Failed calls keep stub semantics; there is no retry or alternate model.
        for status in (500, 429, 307)
            response_status[] = status
            count = length(requests)
            resp = ask(Dict("prompt" => "hi", "task_type" => "code"))
            @test resp.status == 200
            @test JSON.parse(String(resp.body))["source"] == "stub"
            @test length(requests) == count + 1
            @test last(requests).target == "/v1/chat/completions"
        end
        response_status[] = 200
        response_content[] = nothing
        @test call_ai_model("hi"; task_type="code", trusted=true) === nothing

        # No configured model or endpoint means no provider request.
        AI_ROUTING[] = load_ai_routing_policy(Dict{String,String}())
        count = length(requests)
        @test call_ai_model("hi") === nothing
        @test length(requests) == count
        AI_BASE_URL[] = ""
        AI_MODEL[] = "test-fixed"
        @test call_ai_model("hi") === nothing
        @test length(requests) == count
    finally
        AI_BASE_URL[], AI_API_KEY[], AI_MODEL[], REQUIRED_API_KEY[], AI_ROUTING[] = original
        close(server)
    end
end
