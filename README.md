# palantir-julia-integration
Integrating Julia into the Palantir Foundry Platform. Experimental toolkit to integrate Julia workflows into Palantir Foundry via Python bridges, REST endpoints, or containerized apps.
## 🚀 Running the Julia API Server

```bash
docker build -t julia-api ./docker
docker run -p 8080:8080 julia-api
