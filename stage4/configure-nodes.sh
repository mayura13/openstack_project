#!/usr/bin/env bash
set -euo pipefail

echo "=== Stage 4 Node Configuration ==="

# 1. Create OpenStack namespace if it does not exist
if kubectl get namespace openstack >/dev/null 2>&1; then
    echo "[PASS] Namespace openstack already exists"
else
    kubectl create namespace openstack
    echo "[PASS] Namespace openstack created"
fi

# 2. Control-plane node for OpenStack services
kubectl label --overwrite node ctrl-worker \
    openstack-control-plane=enabled \
    openvswitch=enabled

# 3. Compute nodes
kubectl label --overwrite node compute-1 compute-2 \
    openstack-compute-node=enabled \
    openvswitch=enabled

echo
echo "[PASS] OpenStack node labels configured"

echo
kubectl get nodes \
    -L openstack-control-plane,openstack-compute-node,openvswitch

echo
echo "Stage 4 node configuration complete."
