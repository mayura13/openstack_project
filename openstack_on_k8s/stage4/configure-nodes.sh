#!/usr/bin/env bash
# ==============================================================
# stage4/configure-nodes.sh - [4단계] openstack 네임스페이스와 노드 라벨 설정
# ==============================================================
# 네임스페이스(namespace) = Kubernetes 안에서 프로그램들을 묶어 두는 폴더 같은 구분입니다.
# 라벨(label) = 노드에 붙이는 이름표입니다. OpenStack-Helm은 이 라벨을 보고 "어떤 노드에 어떤 Pod를 둘지" 정합니다.
# 이 스크립트가 하는 일
#   1) openstack 네임스페이스 만들기 (이미 있으면 건너뜀)
#   2) ctrl-worker 노드: OpenStack 컨트롤 서비스용 라벨
#   3) compute-1, compute-2 노드: OpenStack 컴퓨트용 라벨
# 여러 번 실행해도 안전합니다. (--overwrite)
# set -euo pipefail : 명령이 하나라도 실패하면 즉시 멈춥니다.
set -euo pipefail

echo "=== Stage 4 Node Configuration ==="

# 1. Create OpenStack namespace if it does not exist
# openstack 네임스페이스가 이미 있는지 확인하고, 없을 때만 만듭니다.
if kubectl get namespace openstack >/dev/null 2>&1; then
    echo "[PASS] Namespace openstack already exists"
else
    kubectl create namespace openstack
    echo "[PASS] Namespace openstack created"
fi

# 2. Control-plane node for OpenStack services
# kubectl label node <노드> 이름=값 : 노드에 라벨을 붙입니다. --overwrite 는 이미 있어도 덮어써서 재실행해도 오류가 나지 않게 합니다.
#   openstack-control-plane=enabled : OpenStack 컨트롤 서비스(Keystone, MariaDB 등)를 이 노드에 둔다는 표시
#   openvswitch=enabled             : Open vSwitch(가상 네트워크 스위치)를 이 노드에서 실행한다는 표시
kubectl label --overwrite node ctrl-worker \
    openstack-control-plane=enabled \
    openvswitch=enabled

# 3. Compute nodes
# openstack-compute-node=enabled : 이 노드에서 nova-compute 와 libvirt(사용자 VM을 실행하는 쪽)를 실행한다는 표시
kubectl label --overwrite node compute-1 compute-2 \
    openstack-compute-node=enabled \
    openvswitch=enabled

echo
echo "[PASS] OpenStack node labels configured"

echo
# -L 라벨이름 : 결과 표에 그 라벨 값을 열로 보여 줍니다. 라벨이 제대로 붙었는지 눈으로 확인합니다.
kubectl get nodes \
    -L openstack-control-plane,openstack-compute-node,openvswitch

echo
echo "Stage 4 node configuration complete."
