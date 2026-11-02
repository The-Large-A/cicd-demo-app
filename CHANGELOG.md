# Changelog

All notable changes to this project. Versions follow [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-02

### Added
- Status page showing version, Jenkins build number, commit, deploy time, pod name and stage.
- `/api/status` JSON endpoint used by the pipeline's smoke test.
- Per-client rate limiting (60 requests/minute, HTTP 429 with `Retry-After`).
- Jenkins pipeline: Gitleaks secret scan, Maven build/test/package, Docker build,
  Trivy image scan, push to ACR, Ansible deployment to AKS with automatic rollback.
- Kubernetes manifests with health probes, resource limits, namespace quota and least-privilege RBAC.
- Ansible playbook that configures the Jenkins server; Azure setup/start/stop/teardown scripts.
