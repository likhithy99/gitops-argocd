#!/usr/bin/env bash
# setup.sh — bootstrap the GitOps cluster in one shot
# Usage: bash setup.sh
set -euo pipefail

ARGOCD_VERSION="v2.11.3"
ARGOCD_NAMESPACE="argocd"

echo "==> [1/4] Creating kind cluster..."
kind create cluster --config kind-config.yaml
kubectl cluster-info --context kind-gitops-argocd

echo "==> [2/4] Installing ArgoCD ${ARGOCD_VERSION}..."
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "${ARGOCD_NAMESPACE}" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "==> [3/4] Waiting for ArgoCD server to become ready (this takes ~60 s)..."
kubectl rollout status deployment/argocd-server -n "${ARGOCD_NAMESPACE}" --timeout=180s

echo "==> [4/4] Applying the ArgoCD Application manifest..."
kubectl apply -f argocd/application.yaml

echo ""
echo "======================================================"
echo "  Setup complete!"
echo "======================================================"
echo ""
echo "Get the initial admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "    -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "Open the UI (in a separate terminal):"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Then visit: https://localhost:8080  (user: admin)"
echo ""
echo "Watch the app sync in the CLI:"
echo "  kubectl get application demo-app -n argocd -w"
echo ""
