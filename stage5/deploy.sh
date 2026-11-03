#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Reuse the versions pinned and verified in Stage 4.
source "${PROJECT_ROOT}/stage4/chart-versions.env"

NAMESPACE="openstack"
OSH_REPO="openstack-helm"
OSH_SOURCE="${HOME}/openstack-helm"
OVERRIDES_DIR="${OSH_SOURCE}/values_overrides"

INGRESS_REPO="ingress-nginx"
INGRESS_CHART_VERSION="4.8.3"

echo "========================================"
echo " Stage 5 - OpenStack-Helm Deployment"
echo "========================================"
echo "OpenStack-Helm tag    : ${OSH_TAG}"
echo "OpenStack-Helm commit : ${OSH_COMMIT}"
echo "Namespace             : ${NAMESPACE}"
echo

osh_overrides() {
    local chart="$1"

    helm osh get-values-overrides \
        -p "${OVERRIDES_DIR}" \
        -c "${chart}" \
        2026.1 ubuntu_noble \
        | tail -n 1
}

deploy_osh_chart() {
    local release="$1"
    local chart="$2"
    local version="$3"
    local values_file="$4"
    local timeout="${5:-600s}"

    echo
    echo "========================================"
    echo " Deploying ${release}"
    echo " Chart: ${chart}"
    echo " Version: ${version}${OSH_CHART_SUFFIX}"
    echo "========================================"

    # get-values-overrides prints the final --values arguments on stdout.
    # shellcheck disable=SC2207
    local overrides=( $(osh_overrides "${chart}") )

    helm upgrade --install "${release}" \
        "${OSH_REPO}/${chart}" \
        --version "${version}${OSH_CHART_SUFFIX}" \
        --namespace "${NAMESPACE}" \
        --timeout "${timeout}" \
        "${overrides[@]}" \
        --values "${values_file}"
}

# 1. RabbitMQ
deploy_osh_chart \
    rabbitmq rabbitmq "${CHART_RABBITMQ}" \
    "${SCRIPT_DIR}/values/values-rabbitmq.yaml"

# 2. MariaDB
deploy_osh_chart \
    mariadb mariadb "${CHART_MARIADB}" \
    "${SCRIPT_DIR}/values/values-mariadb.yaml"

# 3. Memcached
deploy_osh_chart \
    memcached memcached "${CHART_MEMCACHED}" \
    "${SCRIPT_DIR}/values/values-memcached.yaml"

# 4. ingress-nginx
echo
echo "========================================"
echo " Preparing ingress-nginx Helm repository"
echo "========================================"

helm repo add ingress-nginx \
    https://kubernetes.github.io/ingress-nginx \
    --force-update

helm repo update ingress-nginx

echo
echo "========================================"
echo " Deploying ingress-nginx"
echo " Version: ${INGRESS_CHART_VERSION}"
echo "========================================"

helm upgrade --install ingress-nginx \
    "${INGRESS_REPO}/ingress-nginx" \
    --version "${INGRESS_CHART_VERSION}" \
    --namespace "${NAMESPACE}" \
    --timeout 600s \
    --values "${SCRIPT_DIR}/values/values-ingress-nginx.yaml"

# 5. Keystone
deploy_osh_chart \
    keystone keystone "${CHART_KEYSTONE}" \
    "${SCRIPT_DIR}/values/values-keystone.yaml"

# 6. Glance
deploy_osh_chart \
    glance glance "${CHART_GLANCE}" \
    "${SCRIPT_DIR}/values/values-glance.yaml"

# 7. Open vSwitch
deploy_osh_chart \
    openvswitch openvswitch "${CHART_OPENVSWITCH}" \
    "${SCRIPT_DIR}/values/values-openvswitch.yaml"

# 8. libvirt
deploy_osh_chart \
    libvirt libvirt "${CHART_LIBVIRT}" \
    "${SCRIPT_DIR}/values/values-libvirt.yaml"

# 9. Placement
deploy_osh_chart \
    placement placement "${CHART_PLACEMENT}" \
    "${SCRIPT_DIR}/values/values-placement.yaml"

# 10. Nova
deploy_osh_chart \
    nova nova "${CHART_NOVA}" \
    "${SCRIPT_DIR}/values/values-nova.yaml" \
    900s

# Do NOT wait for all pods here.
# nova-compute/libvirt may wait for Neutron agents.

# 11. Neutron
deploy_osh_chart \
    neutron neutron "${CHART_NEUTRON}" \
    "${SCRIPT_DIR}/values/values-neutron.yaml" \
    900s

# 12. Horizon
deploy_osh_chart \
    horizon horizon "${CHART_HORIZON}" \
    "${SCRIPT_DIR}/values/values-horizon.yaml"

echo
echo "========================================"
echo " Stage 5 deployment commands completed"
echo " Run ./stage5/postcheck.sh for validation."
echo "========================================"
