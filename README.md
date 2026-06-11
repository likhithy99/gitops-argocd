# GitOps with ArgoCD on kind

A self-contained demo of the GitOps workflow: ArgoCD watches this Git repo and
keeps a local kind cluster in sync with what's committed — automatically,
continuously, and with self-healing.

---

## What is GitOps and why does it matter?

**GitOps** is an operational model where the *desired state* of your
infrastructure and applications lives entirely in Git. A reconciliation agent
(here, ArgoCD) continuously compares that desired state against the *actual*
state in the cluster and corrects any drift.

| Traditional ops | GitOps |
|---|---|
| `kubectl apply` run by a human or CI script | ArgoCD detects a Git push and applies it |
| Cluster state can drift silently | Any manual change is reverted within seconds |
| "What's actually deployed?" is unclear | The answer is always "whatever is in `main`" |
| Rollback = find the old command | Rollback = `git revert` |

Key benefits:
- **Auditability** — every change is a Git commit with author + message.
- **Consistency** — dev, staging, and prod can share identical manifests.
- **Self-healing** — accidental or malicious live edits are auto-corrected.
- **Disaster recovery** — re-applying the repo rebuilds the cluster from scratch.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  GitHub repo: likhithy99/gitops-argocd                      │
│                                                             │
│  apps/demo-app/                                             │
│    namespace.yaml   deployment.yaml   service.yaml          │
└────────────────────────┬────────────────────────────────────┘
                         │  polls every 3 min (or webhook)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  kind cluster  (control-plane + worker)                     │
│                                                             │
│  namespace: argocd                                          │
│    ArgoCD server  ←──── argocd/application.yaml             │
│         │                                                   │
│         │  reconciles (apply / prune / self-heal)           │
│         ▼                                                   │
│  namespace: demo-app                                        │
│    Deployment: demo-app  (nginxdemos/hello, 2 replicas)     │
│    Service:    demo-app  (NodePort 30080)                   │
└─────────────────────────────────────────────────────────────┘
         ▲
         │  http://localhost:30080
    Your browser
```

---

## Prerequisites

| Tool | Install |
|---|---|
| [Docker Desktop](https://docs.docker.com/get-docker/) | running |
| [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | `brew install kind` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | `brew install kubectl` |
| [argocd CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) | `brew install argocd` (optional but useful) |

---

## Step-by-step walkthrough

### 0 — Fork / push this repo to GitHub

ArgoCD needs to pull manifests from a real URL.

```bash
# After forking on GitHub:
git clone https://github.com/<YOUR-USERNAME>/gitops-argocd.git
cd gitops-argocd

# Update the repoURL in the Application manifest to point at YOUR fork:
sed -i '' 's|https://github.com/likhithy99/gitops-argocd|https://github.com/<YOUR-USERNAME>/gitops-argocd|g' \
  argocd/application.yaml

git add argocd/application.yaml
git commit -m "chore: set repoURL to my fork"
git push
```

---

### 1 — Create the kind cluster

```bash
kind create cluster --config kind-config.yaml
```

Verify:

```bash
kubectl cluster-info --context kind-gitops-argocd
kubectl get nodes
# NAME                          STATUS   ROLES           AGE
# gitops-argocd-control-plane   Ready    control-plane   ...
# gitops-argocd-worker          Ready    <none>          ...
```

---

### 2 — Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.11.3/manifests/install.yaml
```

Wait for it to be ready (~60 s):

```bash
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
```

---

### 3 — Access the ArgoCD UI

Open a **new terminal** and keep the port-forward running:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Open your browser at **https://localhost:8080**
Login: `admin` / `<password from above>`

> Accept the self-signed cert warning — this is a local dev cluster.

Optional — log in via the CLI:

```bash
argocd login localhost:8080 \
  --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d) \
  --insecure
```

---

### 4 — Apply the Application manifest

This tells ArgoCD *what* to watch and *where* to deploy it:

```bash
kubectl apply -f argocd/application.yaml
```

Watch ArgoCD sync the app (takes ~10–30 s for the first sync):

```bash
kubectl get application demo-app -n argocd -w
# NAME       SYNC STATUS   HEALTH STATUS
# demo-app   Synced        Healthy
```

Check the deployed resources:

```bash
kubectl get all -n demo-app
# NAME                            READY   STATUS    RESTARTS   AGE
# pod/demo-app-xxxxxxxxxx-xxxxx   1/1     Running   0          ...
# pod/demo-app-xxxxxxxxxx-xxxxx   1/1     Running   0          ...
#
# NAME               TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
# service/demo-app   NodePort   10.96.x.x      <none>        80:30080/TCP   ...
#
# NAME                       READY   UP-TO-DATE   AVAILABLE
# deployment.apps/demo-app   2/2     2            2
```

View the app in the browser (may need to wait for all nodes to be ready):

```bash
# Get the kind node's IP
kubectl get nodes -o wide

# Or just curl through the NodePort:
curl http://localhost:30080
```

---

### DEMO 1 — Auto-sync: push a change, watch it deploy

This demo shows ArgoCD detecting a Git change and applying it without any
manual `kubectl apply`.

**1. Change the replica count in Git:**

```bash
# Edit apps/demo-app/deployment.yaml — change replicas: 2 → replicas: 3
sed -i '' 's/replicas: 2/replicas: 3/' apps/demo-app/deployment.yaml
```

**2. Commit and push:**

```bash
git add apps/demo-app/deployment.yaml
git commit -m "feat: scale demo-app to 3 replicas"
git push
```

**3. Watch ArgoCD pick it up** (default poll interval is 3 minutes; you can
   also click "Refresh" in the UI or force it via the CLI):

```bash
# Force an immediate refresh via the CLI (optional):
argocd app get demo-app --refresh

# Watch pods — you should see a third pod appear
kubectl get pods -n demo-app -w
```

**4. Confirm:**

```bash
kubectl get deployment demo-app -n demo-app
# READY: 3/3
```

---

### DEMO 2 — Self-heal: manually scale down, watch ArgoCD revert it

This demo shows that the cluster state is *always* driven by Git — a manual
live edit is detected and reversed automatically.

**1. Manually scale the deployment down to 1 replica:**

```bash
kubectl scale deployment demo-app -n demo-app --replicas=1
```

**2. Immediately watch the pods:**

```bash
kubectl get pods -n demo-app -w
```

Within ~3–10 seconds ArgoCD detects the drift (live=1, desired=3 from Git)
and scales back up. You will see two new pods spin up.

**3. Confirm the revert:**

```bash
kubectl get deployment demo-app -n demo-app
# READY: 3/3  ← back to what Git says
```

**What happened under the hood:**
ArgoCD's application controller polls every 3 seconds (hard-coded jitter).
When `selfHeal: true` is set and a diff is detected, it immediately triggers
a sync — no human intervention required.

---

### DEMO 3 (bonus) — Prune: delete a manifest, watch ArgoCD clean up

**1. Delete the Service manifest from Git:**

```bash
git rm apps/demo-app/service.yaml
git commit -m "chore: remove service"
git push
```

**2. ArgoCD detects the missing manifest and deletes the live Service:**

```bash
argocd app get demo-app --refresh
kubectl get svc -n demo-app
# No resources found  ← pruned automatically
```

**3. Restore it:**

```bash
git revert HEAD
git push
```

---

### Verify everything is healthy

```bash
# ArgoCD Application status
kubectl get application -n argocd

# Full sync detail via CLI
argocd app get demo-app

# Live resources
kubectl get all -n demo-app
```

---

### Tear down

```bash
kind delete cluster --name gitops-argocd
```

This removes the entire cluster (ArgoCD, demo-app, everything).
Your Git repo and local files are untouched.

---

## File structure

```
gitops-argocd/
├── kind-config.yaml            # kind cluster: 1 control-plane + 1 worker
├── setup.sh                    # one-shot bootstrap script
├── apps/
│   └── demo-app/
│       ├── namespace.yaml      # demo-app namespace
│       ├── deployment.yaml     # nginxdemos/hello Deployment
│       └── service.yaml        # NodePort Service → :30080
└── argocd/
    └── application.yaml        # ArgoCD Application CRD
```

---

## Key ArgoCD concepts recap

| Concept | What it does |
|---|---|
| **Application** | A CRD that links a Git path to a cluster destination |
| **Automated sync** | ArgoCD applies diffs without manual intervention |
| **selfHeal** | Reverts any live drift back to the Git-defined state |
| **prune** | Removes live resources whose manifests no longer exist in Git |
| **Refresh** | Forces ArgoCD to re-fetch the repo (bypass the 3-min poll) |
| **Sync** | The act of applying Git state to the cluster |
| **Health** | ArgoCD's assessment of whether live resources are operational |

---

## Troubleshooting

**ArgoCD can't reach the repo (ComparisonError)**

Make sure you updated `repoURL` in `argocd/application.yaml` to point at your
fork and that the repo is public (or you've added repo credentials in ArgoCD).

**App stuck in `OutOfSync` forever**

```bash
argocd app sync demo-app --force
```

**Port 8080 already in use**

```bash
kubectl port-forward svc/argocd-server -n argocd 8081:443
# Then open https://localhost:8081
```

**kind cluster not found after restart**

Docker Desktop must be running before `kind` commands work.
