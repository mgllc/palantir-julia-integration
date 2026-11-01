# Workspace rebuild

The `Workspace rebuild` workflow runs on every branch push and pull request, on manual dispatch, and daily at 04:12 UTC. GitHub may delay scheduled runs. Each job has a 15-minute limit, repository/ref concurrency, read-only repository permission, and checkout credentials are removed.

## Verified scope

Julia unit tests, clean container rebuild, localhost health smoke test.

The exact reproducible commands are maintained in `.github/workflows/workspace-rebuild.yml`. Each execution uploads `workspace-rebuild.json` with repository, commit, run, status, and validation scope; retention is 30 days. A failed check fails the job. Inspect the overall run conclusion as well as its artifact.

This is a fresh container rebuild, not a dependency-lock reproducibility claim: the existing project has no Manifest.toml and uses the Julia 1.10 image tag. Unit and localhost health checks exercise the resulting resolved build.

## Recovery and limits

Inspect the failed step, repair the cause in a branch, and rerun CI. Do not remove checks to make a failure green. Existing security/CI/deployment workflows remain independent. No secrets, customer data, application deployment, or repository settings are changed. Runtime behavior is not claimed for documentation or template repositories.

To pause recurring rebuilds, disable this workflow in GitHub Actions. To roll back the addition, revert its introducing commit. Preserve existing workflows and user changes.
