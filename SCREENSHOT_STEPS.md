# CIA 2 CI/CD Pipeline: Screenshot Steps

Follow the parts **in order**: Parts A and B capture version 1.0.0, so take them **before**
making the change in Part C. Use **Win + Shift + S** (Snipping Tool, rectangle mode) and save
the files as `ss01.png`, `ss02.png`, … into a `screenshots` folder next to this file.

| Thing | Value |
|---|---|
| Jenkins | http://20.2.119.46:8080 (user `admin`) |
| App | the IP in the last line of the Jenkins **Verify** stage log (`Application is live at …`) |
| Registry | `acrcicd69d44246c4.azurecr.io` |
| Resource group | `rg-cicd-demo` (region East Asia) |

## Before you start

1. If you stopped everything last time, open Cloud Shell and run:

   ```
   git clone https://github.com/The-Large-A/cicd-demo-app.git && cd cicd-demo-app
   bash azure/start.sh
   ```

2. In the **same** Cloud Shell, connect `kubectl` to the cluster (once per Cloud Shell session):

   ```
   az aks get-credentials -g rg-cicd-demo -n aks-cicd-demo --admin --overwrite-existing
   ```

3. Maximise the browser and Cloud Shell windows so outputs are not cut off.

## Part A: Cloud resources (version 1.0.0)

| # | Where | What to capture |
|---|---|---|
| 1 | Azure portal → **Resource groups → rg-cicd-demo** | The resource list: Kubernetes service, container registry, VM, disk, public IP, NSG, network interface, virtual network |
| 2 | Portal → **Kubernetes services → aks-cicd-demo → Node pools** | 1 node, size `Standard_B2als_v2`, status Succeeded/Running, Kubernetes version |
| 3 | Portal → **Container registries → acrcicd69d44246c4 → Repositories → cicd-demo-app** | The tag `1.0.0-6e2271c` |
| 4 | Cloud Shell: `kubectl get nodes -o wide` | Node `Ready` |
| 5 | Cloud Shell: `kubectl -n cicd-demo get deployment,pods,service -o wide` | Deployment `2/2`, both pods `Running`, service `LoadBalancer` with an **EXTERNAL-IP** |
| 6 | Browser: the app URL | Status LIVE, Version **1.0.0**, Build **#1**, Commit `6e2271c`, Pod, Stage *Production (AKS)* |

## Part B: The pipeline (build #1)

| # | Where | What to capture |
|---|---|---|
| 7 | Jenkins → **cicd-demo-app → main** (Stage View) | All stages green, Checkout → Verify |
| 8 | Stage View → hover the **Secret Scan** cell → **Logs** | `no leaks found` |
| 9 | **Test** stage log | `Tests run: 14, Failures: 0, Errors: 0` and `BUILD SUCCESS` |
| 10 | Build #1 → **Tests** (left menu) | Test result page: 14 passed |
| 11 | **Docker Build** stage log | `naming to …azurecr.io/cicd-demo-app:1.0.0-6e2271c` |
| 12 | **Image Scan** stage log | Trivy report table with **0** vulnerabilities |
| 13 | **Push** stage log | `1.0.0-6e2271c: digest: sha256:…` |
| 14 | **Deploy** stage log | Ansible tasks, `Deployed … live at http://…` and `PLAY RECAP … failed=0` |
| 15 | **Verify** stage log | `kubectl get deployment,pods,service` output and `Application is live at …` |
| 16 | Jenkins → **Manage Jenkins → Credentials** | The 3 credential IDs (secrets are hidden) |
| 17 | GitHub → repo **Settings → Webhooks** → the webhook → **Recent Deliveries** | Green tick |

## Part C: Change and automatic redeploy (version 1.1.0)

Note: Dependabot's pull request #1 (Java 21 → 24 base image) was merged, and the pipeline
refused to release it: `main` builds **#2 and #3** failed before Deploy, so the live app
stayed on 1.0.0. This release puts the base image back on Java 21 LTS. The `Dockerfile` (Java 21 +
Alpine security updates), `.github/dependabot.yml` (ignore major Java updates) and `azure/common.sh` changes are
already made in your folder; they go into the same commit.

Then do this on your laptop in the `CIA2 CICD Pipeline` folder, in **Git Bash**.

1. Create a feature branch:

   ```
   git switch main && git pull
   git switch -c feature/release-1.1.0
   ```

2. Make the change (VS Code is fine):
   * `pom.xml`: change `<version>1.0.0</version>` to `<version>1.1.0</version>`
   * `CHANGELOG.md`: add at the top, under the first heading:

     ```
     ## [1.1.0] - <today's date>

     ### Changed
     - Release 1.1.0 to demonstrate an automatic pipeline redeploy.

     ### Fixed
     - Base image back on Java 21 LTS; Dependabot now ignores major Java updates.
     - Apply Alpine security updates when building the image (`apk upgrade`).
     ```

3. Check it builds, then commit and push:

   ```
   ./mvnw -q verify
   git add pom.xml CHANGELOG.md SCREENSHOT_STEPS.md Dockerfile .github/dependabot.yml azure/common.sh README.md
   git commit -m "feat: release 1.1.0"
   git push -u origin feature/release-1.1.0
   ```

| # | Where | What to capture |
|---|---|---|
| 18 | VS Code **Source Control** (or `git diff`) before committing | The `1.0.0 → 1.1.0` version and the Java `24 → 21` base image change |
| 19 | Git Bash | The `git commit` and `git push` output |
| 20 | GitHub → **Compare & pull request** → create it | The PR page; wait for the Jenkins check to turn green |
| 21 | Jenkins → **cicd-demo-app → Pull Requests → PR-<number>** | PR build green, and it **stops after Package** (PRs never deploy) |
| 22 | GitHub PR page | `continuous-integration/jenkins/pr-merge` ✓ and the **Merge** button enabled |

4. Click **Merge pull request → Confirm merge**. Jenkins starts the `main` build by itself (webhook).

| # | Where | What to capture |
|---|---|---|
| 23 | Jenkins → **main** Stage View | Build **#4** `v1.1.0` green, above the red #2 and #3 and the green #1 |
| 24 | Build #4 → **Console Output** (top) | `Started by GitHub push` or `Branch event`, i.e. not started by hand |
| 25 | Portal → ACR → **Repositories → cicd-demo-app** | Both tags: `1.0.0-…` and `1.1.0-…` |
| 26 | Cloud Shell: `kubectl -n cicd-demo get pods -o wide` | New pod names, both `Running` |
| 27 | Cloud Shell: `kubectl -n cicd-demo rollout history deployment/cicd-demo-app` | Revisions with `Jenkins build #1 …` and `Jenkins build #4 …` (#2 and #3 never reached Deploy) |
| 28 | Browser: the app URL (refresh) | Version **1.1.0**, Build **#4**, the new commit |

## Part D: Security demonstrations

**The pipeline blocks an unsafe dependency update** (this already happened with Dependabot's PR #1):

| # | Where | What to capture |
|---|---|---|
| 29 | Jenkins → **main** → build **#3** → the red stage → **Logs** | Why the Java 24 image was refused; the live app stayed on 1.0.0 |

**Gitleaks blocks a leaked secret.** In Git Bash:

```
git switch main && git pull
git switch -c demo/leaked-secret
echo "payment.api-key=$(openssl rand -hex 20)" > src/main/resources/payment.properties
git add src/main/resources/payment.properties
git commit -m "feat: add payment settings"
git push -u origin demo/leaked-secret
```

Open a pull request for the branch on GitHub (do **not** merge it).

| # | Where | What to capture |
|---|---|---|
| 30 | Jenkins → **Pull Requests → PR-<number>** Stage View | **Secret Scan** red; Build, Test and later stages never ran |
| 31 | That stage's log | `RuleID: generic-api-key`, `File: src/main/resources/payment.properties`, `Secret: REDACTED`, `leaks found: 1` |
| 32 | GitHub PR page | Jenkins check ✗ and merging **blocked** |

Clean up afterwards: on GitHub click **Close pull request** and **Delete branch**, then in Git Bash:

```
git switch main
git branch -D demo/leaked-secret
```

**Rate limiting.** In Cloud Shell (replace the IP). 130 requests, because each of the 2 pods
allows 60 per minute:

```
APP=http://<app-ip>
for i in $(seq 1 130); do curl -s -o /dev/null -w "%{http_code}\n" $APP/api/status; done | sort | uniq -c
curl -si $APP/api/status | head -5
```

| # | Where | What to capture |
|---|---|---|
| 33 | Cloud Shell | About 120 × `200` then `429`s, and the `HTTP/1.1 429` response with `Retry-After` |

**Least privilege.** In Cloud Shell:

```
az aks get-credentials -g rg-cicd-demo -n aks-cicd-demo --admin --file ~/admin.kubeconfig --overwrite-existing
bash azure/make-jenkins-kubeconfig.sh ~/admin.kubeconfig ~/jenkins-check.kubeconfig
rm ~/jenkins-check.kubeconfig
```

| # | Where | What to capture |
|---|---|---|
| 34 | Cloud Shell | The permissions table: deployments/services **yes**, secrets/namespaces/kube-system **no** |

## Part E: Cost controls (optional)

| # | Where | What to capture |
|---|---|---|
| 35 | Portal → **Cost Management → Budgets** | `budget-cicd-demo`, ₹1,300 (≈ $15) per month with alerts at 50 / 80 / 100 % |
| 36 | Portal → **Virtual machines → vm-jenkins → Auto-shutdown** | Enabled, 17:30 UTC (23:00 IST) |
| 37 | Cloud Shell: `bash azure/stop.sh` | Old images pruned, AKS and VM stopped |

## If something goes wrong

* **Jenkins page does not load**: your IP changed (WARP). In Cloud Shell run `bash azure/start.sh <new-ip>`.
* **App page shows "Too many requests"**: the rate limiter; wait for the seconds it shows.
* **A Jenkins stage is red**: click the cell → **Logs**, and send the last 40 lines.
* **`kubectl` says it cannot connect**: run step 2 of *Before you start* again (new Cloud Shell session).
