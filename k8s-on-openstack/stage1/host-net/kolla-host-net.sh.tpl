#!/bin/bash
# Kolla single-NIC host network: @KOLLA_IF@ + veth pair + firewall allow/NAT. Idempotent.
# OpenInfra Lab Kit stage1 이 생성했다. 값은 versions.env 에서 온다.
set -eu
IPT=/usr/sbin/iptables
ip link show @KOLLA_IF@ >/dev/null 2>&1 || ip link add @KOLLA_IF@ type dummy
ip addr show dev @KOLLA_IF@ | grep -qF '@VIP_CIDR@' || ip addr add @VIP_CIDR@ dev @KOLLA_IF@
ip link set @KOLLA_IF@ up
ip link show @EXT_IF@ >/dev/null 2>&1 || ip link add @EXT_IF@ type veth peer name @EXT_HOST_IF@
ip addr show dev @EXT_HOST_IF@ | grep -qF '@EXT_GW_CIDR@' || ip addr add @EXT_GW_CIDR@ dev @EXT_HOST_IF@
ip link set @EXT_IF@ up
ip link set @EXT_HOST_IF@ up
$IPT -C INPUT -i @EXT_HOST_IF@ -j ACCEPT 2>/dev/null || $IPT -I INPUT 1 -i @EXT_HOST_IF@ -j ACCEPT
$IPT -C INPUT -d @VIP@/32 ! -i @HOST_NIC@ -j ACCEPT 2>/dev/null || $IPT -I INPUT 1 -d @VIP@/32 ! -i @HOST_NIC@ -j ACCEPT
$IPT -C FORWARD -i @EXT_HOST_IF@ -o @HOST_NIC@ -j ACCEPT 2>/dev/null || $IPT -I FORWARD 1 -i @EXT_HOST_IF@ -o @HOST_NIC@ -j ACCEPT
$IPT -C FORWARD -i @HOST_NIC@ -o @EXT_HOST_IF@ -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || $IPT -I FORWARD 2 -i @HOST_NIC@ -o @EXT_HOST_IF@ -m state --state RELATED,ESTABLISHED -j ACCEPT
$IPT -t nat -C POSTROUTING -s @EXT_NET_CIDR@ -o @HOST_NIC@ -j MASQUERADE 2>/dev/null || $IPT -t nat -A POSTROUTING -s @EXT_NET_CIDR@ -o @HOST_NIC@ -j MASQUERADE
# --- kit:extra-rules  (이후 단계가 필요한 규칙을 이 아래에 멱등 형태로 추가한다. 예: 3~4단계의 kind 대역 NAT·FORWARD)
