FROM julia:1.12

# Install curl for the HEALTHCHECK probe.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy project manifest and resolve dependencies before copying source so that
# the package layer is cached independently of source changes.
COPY Project.toml .
RUN julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# Copy source after dependencies are resolved.
COPY src/ ./src/

EXPOSE 8080

# Docker-native liveness probe: marks the container unhealthy after 3
# consecutive failures so orchestrators (Compose restart:always, Swarm, k8s)
# can restart it automatically.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://localhost:${API_PORT:-8080}/health" \
        | grep -q '"status"' || exit 1

# API_KEY can be injected at runtime; leave unset for unauthenticated (dev) mode.
# Example: docker run -e API_KEY=mysecret ...
CMD ["julia", "--project=.", "src/api.jl"]
