# Deployment-owned routing policy. Model names are opaque provider identifiers;
# no model availability, quality, or price is inferred from a name or prompt.
struct AIRoutingPolicy
    default_model::String
    task_models::Dict{String,String}
    allowed_models::Set{String}
    trust_task_metadata::Bool
    max_prompt_bytes::Int
    max_output_tokens::Int
    output_token_parameter::String
    service_tier::String
end

function load_ai_routing_policy(env::AbstractDict=ENV)
    default_model = strip(get(env, "AI_DEFAULT_MODEL", ""))
    allowed = Set(String(strip(m)) for m in split(get(env, "AI_ALLOWED_MODELS", default_model), ',')
                  if !isempty(strip(m)))
    routes_json = get(env, "AI_TASK_MODELS", "")
    raw_routes = JSON.parse(isempty(strip(routes_json)) ? "{}" : routes_json)
    raw_routes isa AbstractDict || throw(ArgumentError("AI_TASK_MODELS must be a JSON object"))
    length(raw_routes) <= 64 || throw(ArgumentError("AI_TASK_MODELS may contain at most 64 routes"))
    routes = Dict{String,String}()
    for (task, model) in raw_routes
        occursin(r"^[a-z][a-z0-9_]{0,63}$", task) ||
            throw(ArgumentError("AI_TASK_MODELS keys must be lowercase task identifiers"))
        model isa AbstractString && !isempty(strip(model)) ||
            throw(ArgumentError("AI_TASK_MODELS values must be nonempty model names"))
        model in allowed || throw(ArgumentError("Every task model must be in AI_ALLOWED_MODELS"))
        routes[task] = model
    end
    isempty(default_model) || default_model in allowed ||
        throw(ArgumentError("AI_DEFAULT_MODEL must be in AI_ALLOWED_MODELS"))
    isempty(routes) || !isempty(default_model) ||
        throw(ArgumentError("Task routing requires AI_DEFAULT_MODEL for unknown tasks"))

    trust = get(env, "AI_TRUST_TASK_METADATA", "false")
    trust in ("true", "false") || throw(ArgumentError("AI_TRUST_TASK_METADATA must be true or false"))
    input_limit = parse(Int, get(env, "AI_MAX_PROMPT_BYTES", "10240"))
    1 <= input_limit <= 1_048_576 || throw(ArgumentError("AI_MAX_PROMPT_BYTES must be between 1 and 1048576"))
    output_limit = parse(Int, get(env, "AI_MAX_OUTPUT_TOKENS", "512"))
    1 <= output_limit <= 4096 || throw(ArgumentError("AI_MAX_OUTPUT_TOKENS must be between 1 and 4096"))
    parameter = get(env, "AI_OUTPUT_TOKEN_PARAMETER", "max_tokens")
    parameter in ("max_tokens", "max_completion_tokens") ||
        throw(ArgumentError("AI_OUTPUT_TOKEN_PARAMETER must be max_tokens or max_completion_tokens"))
    service_tier = get(env, "AI_SERVICE_TIER", "")
    service_tier in ("", "default") ||
        throw(ArgumentError("AI_SERVICE_TIER must be empty or default"))
    return AIRoutingPolicy(default_model, routes, allowed, trust == "true",
                           input_limit, output_limit, parameter, service_tier)
end

# A nonempty AI_MODEL is the existing deployment-level override. The HTTP body
# cannot supply an override. Unknown/untrusted tasks always use the default.
function select_ai_model(policy::AIRoutingPolicy; task_type::AbstractString="",
                         trusted::Bool=false, model_override::AbstractString="")
    !isempty(model_override) && return (model=String(model_override), reason="explicit_override")
    if trusted && haskey(policy.task_models, task_type)
        return (model=policy.task_models[task_type], reason="task_route")
    end
    return (model=policy.default_model, reason="default")
end
