# CI/CD Demo App

A small Java status page that is built, tested, scanned, containerised and deployed to
**Azure Kubernetes Service** automatically by **Jenkins** whenever code is merged to `main`.
Built for CIA 2: *Design and Implementation of an End-to-End Cloud-Based CI/CD Pipeline*.

```
 Developer                      Azure (resource group rg-cicd-demo)
 ─────────                      ──────────────────────────────────────────────────────────────
 git push ─► GitHub ─webhook─►  Jenkins VM (Ubuntu 24.04, configured by Ansible)
                                  Checkout → Secret Scan (Gitleaks) → Build → Test → Package (Maven)
                                  Docker Build → Image Scan (Trivy) → Push ───────► ACR (registry)
                                  Deploy (Ansible) → Verify ──────────────────────► AKS (1 node)
                                                                                     │
 Browser ◄───────────────────────────── public IP (LoadBalancer) ◄──── 2 app pods ◄──┘
```

## Tools

| Purpose | Tool |
|---|---|
| Source control | Git + GitHub (feature branches, pull requests, protected `main`) |
| Build and unit tests | Maven (wrapper `./mvnw`), JUnit 5, Spring Boot 4 / Java 21 |
| CI/CD server | Jenkins LTS, Multibranch Pipeline (`Jenkinsfile`) |
| Secret scanning | Gitleaks |
| Container + image scanning | Docker, Trivy |
| Registry | Azure Container Registry (Basic) |
| Orchestration | Azure Kubernetes Service (free tier, 1 × Standard_B2als_v2) |
| Configuration management / deployment | Ansible (`ansible/jenkins.yml`, `ansible/deploy.yml`) |

## Repository layout

```
├── Jenkinsfile                 pipeline definition
├── pom.xml, mvnw               Maven build (the version here is shown on the page)
├── src/main/...                Spring Boot app: status page, /api/status, rate limiter
├── src/test/...                unit + integration tests (14)
├── Dockerfile, .dockerignore   runtime image (non-root, read-only friendly)
├── k8s/                        namespace, quota, RBAC, Deployment, Service
├── ansible/                    jenkins.yml (server setup), deploy.yml (release), inventory, vars
├── azure/                      setup / start / stop / teardown scripts for Cloud Shell
├── .gitleaks.toml              secret-scanning rules
└── .github/                    Dependabot and pull request template
```

## Pipeline stages

| Stage | Runs on | What it does |
|---|---|---|
| Checkout | every branch / PR | Clone the commit, read the version from `pom.xml` |
| Secret Scan | every branch / PR | `gitleaks git` over the whole history; any leaked key fails the build |
| Build | every branch / PR | `./mvnw compile` |
| Test | every branch / PR | `./mvnw test`, results published to Jenkins (JUnit) |
| Package | every branch / PR | `./mvnw package`, jar archived |
| Docker Build | `main` | Image tagged `<version>-<commit>` |
| Image Scan | `main` | Trivy; fails on fixable CRITICAL vulnerabilities |
| Push | `main` | Push to ACR |
| Deploy | `main` | `ansible-playbook ansible/deploy.yml`: rolling update, smoke test, automatic rollback |
| Verify | `main` | `kubectl get` + HTTP check of the public endpoint |

## Run it locally

```bash
./mvnw verify                                   # build + all tests
./mvnw package -DskipTests
docker build -t cicd-demo-app:local .
docker run --rm -p 8080:8080 cicd-demo-app:local  # open http://localhost:8080
```

## Cloud setup (one time)

Everything below runs in **Azure Cloud Shell** (portal → `>_` icon → Bash). It already has
`az`, `kubectl`, `git` and Python; nothing needs installing on your laptop.

1. **Create the Azure resources** (find your laptop's public IP at <https://api.ipify.org>):

   ```bash
   git clone https://github.com/<your-username>/cicd-demo-app.git && cd cicd-demo-app
   bash azure/setup.sh <your-public-ip>
   ```

   It first runs `azure/preflight.sh`, a read-only check that your subscription allows
   everything (region, VM size, vCPU and public-IP quotas, policies, your Owner role, Ubuntu
   image, AKS) and stops before creating anything if not. Then it creates the budget alert,
   ACR, AKS, the Jenkins VM and its firewall, and writes the files Jenkins needs to
   `~/cicd-outputs/`. It takes about 10–15 minutes. You can run `bash azure/preflight.sh` on
   its own at any time.

2. **Configure Jenkins with Ansible** (asks you to choose the Jenkins admin password):

   ```bash
   ~/ansible-venv/bin/ansible-playbook ansible/jenkins.yml -e @$HOME/cicd-outputs/ansible-vars.yml
   ```

3. **Add the credentials** in Jenkins (`http://<vm-ip>:8080` → Manage Jenkins → Credentials →
   System → Global credentials → Add Credentials):

   | ID | Kind | Value |
   |---|---|---|
   | `acr-credentials` | Username with password | from `cat ~/cicd-outputs/acr-credentials.yml` |
   | `aks-kubeconfig` | Secret file | `~/cicd-outputs/jenkins-kubeconfig.yaml` (Cloud Shell → Manage files → Download) |
   | `github-token` | Username with password | your GitHub username + a fine-grained token for this repo with *Contents: read*, *Metadata: read*, *Pull requests: read*, *Commit statuses: read and write* |

4. **Create the pipeline job**: New Item → name `cicd-demo-app` → **Multibranch Pipeline** →
   Branch Sources → Add source → **GitHub** → credentials `github-token` → repository URL →
   keep the default behaviours (discover branches and pull requests) → Save.

5. **Add the webhook** in GitHub (repo → Settings → Webhooks → Add webhook):
   payload URL `http://<vm-ip>:8080/github-webhook/`, content type `application/json`,
   *Send me everything*.

6. **Protect `main`** (repo → Settings → Rules → Rulesets → New branch ruleset): target the
   default branch, *Require a pull request before merging*, *Require status checks to pass*
   → add `continuous-integration/jenkins/pr-merge`, *Block force pushes*.

## Releasing a change

```bash
git switch -c feature/my-change
# edit code, bump <version> in pom.xml, add a CHANGELOG entry
./mvnw verify
git commit -am "feat: describe the change"
git push -u origin feature/my-change
```

Open a pull request. Jenkins builds and tests it and reports the result on the PR. Merging it
runs the full pipeline on `main`, and the new version, build number and commit appear on the
page within a few minutes, with no downtime (rolling update, `maxUnavailable: 0`).

## Keeping Azure costs down

| Control | Where |
|---|---|
| $15 monthly budget with email alerts at 50 / 80 / 100 % | `azure/setup.sh` |
| AKS free tier, one small node, 30 GB disk, no monitoring add-on, no autoscaler | `azure/setup.sh` |
| Jenkins VM shuts down every night at 23:00 IST | `azure/setup.sh` |
| AKS cluster is stopped every night at 22:45 IST by a timer on the VM | `ansible/jenkins.yml` |
| `bash azure/stop.sh` stops both and deletes all but the newest 5 images | `azure/stop.sh` |
| Namespace quota: max 4 pods, 1 CPU / 1 GiB requested, 1 load balancer | `k8s/quota.yaml` |
| Branch and PR builds never touch Azure; only `main` pushes and deploys | `Jenkinsfile` |
| App rate limit: 60 requests/minute per client IP (HTTP 429 beyond that) | `RateLimitFilter.java` |

Start a work session with `bash azure/start.sh` and end it with `bash azure/stop.sh`.
`bash azure/check.sh` is a read-only health check of everything the project keeps in Azure,
Kubernetes and Jenkins; it works whether things are running or stopped.
After the viva, `bash azure/teardown.sh` deletes everything.

## Security

* **Gitleaks** blocks any commit that contains a key, password or token.
* **Trivy** blocks images with fixable CRITICAL vulnerabilities.
* Jenkins deploys with a **service account limited to one namespace**. It cannot read secrets
  or touch the rest of the cluster.
* Credentials live only in the Jenkins credential store; `.gitignore` and `.dockerignore`
  keep kubeconfigs and outputs out of Git and out of the image.
* Containers run as a **non-root user** with a read-only root filesystem, no Linux
  capabilities, and the namespace enforces the Kubernetes *restricted* Pod Security standard.
* The Jenkins VM firewall only allows SSH from Cloud Shell and port 8080 from your IP and
  GitHub's webhook servers. Tool downloads are pinned and checked against SHA-256 checksums.

Known limitations: HTTP only (no TLS certificate), a single AKS node (no high availability),
the rate limit is counted per pod, and the ACR admin account is used instead of a
workload identity to keep the setup simple.

## Troubleshooting

* **`RequestDisallowedByAzure`**: your subscription does not allow that region. `setup.sh`
  prints the allowed list; re-run with `LOCATION=<region> bash azure/setup.sh <ip>`.
* **Webhook shows a timeout in GitHub**: the VM is stopped (`bash azure/start.sh`) or your
  firewall rule is stale.
* **Jenkins not reachable from your laptop**: your IP changed. Run `bash azure/start.sh <new-ip>`.
* **App page says "Too many requests"**: wait for the `Retry-After` seconds; it is the rate limiter.
