FROM julia:1.10

# Install required packages
RUN julia -e 'using Pkg; Pkg.add(["HTTP", "JSON"])'

# Set working directory
WORKDIR /app

# Copy source
COPY src/ ./src/
COPY Project.toml .
COPY Manifest.toml .

# Run server
CMD ["julia", "src/api.jl"]
