FROM julia:1.10

WORKDIR /app

# Copy project manifest and resolve dependencies before copying source so that
# the package layer is cached independently of source changes.
COPY Project.toml .
RUN julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Copy source after dependencies are resolved.
COPY src/ ./src/

# API_KEY can be injected at runtime; leave unset for unauthenticated (dev) mode.
# Example: docker run -e API_KEY=mysecret ...
CMD ["julia", "--project=.", "src/api.jl"]
