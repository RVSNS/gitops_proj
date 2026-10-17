#!/usr/bin/bash

set -euo pipefail

cluster_name="alpha"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <up/down>"
    exit 1
fi

if [[ $1 == "up" ]]; then
    echo "Bringing the cluster up..."

    # Check if the cluster is already up
    cluster_names=$(k3d cluster list)
    if echo "$cluster_names" | grep -q "$cluster_name"; then
        echo "Cluster '$cluster_name' is already up."
    else
        k3d cluster create "$cluster_name"
    fi

    # install argocd in the cluster
    kubectl create namespace argocd
    kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    kubectl rollout status deployment/argocd-server -n argocd --timeout=600s

    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d   

    # open argocd in browser
    kubectl port-forward svc/argocd-server -n argocd 8080:443 & 
    echo "ArgoCD is available at https://localhost:8080"

    # apply the root-app
    kubectl apply -f bootstrap/root-app.yaml

    exit 0
elif [[ $1 == "down" ]]; then
    echo "Bringing the cluster down..."
    k3d cluster delete "$cluster_name"
    exit 0
else
    echo "Invalid argument: $1"
    echo "Usage: $0 <up/down>"
    exit 1
fi