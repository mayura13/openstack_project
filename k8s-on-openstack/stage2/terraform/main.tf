terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "3.4.0"
    }
  }
}

# 인증은 환경변수(source /etc/kolla/admin-openrc.sh)를 사용한다.
provider "openstack" {}

# --- 외부 네트워크 (호스트 veth-ext -> br-ex -> physnet1) ---
resource "openstack_networking_network_v2" "ext" {
  name     = "ext-net"
  external = true
  segments {
    network_type     = "flat"
    physical_network = "physnet1"
  }
}

resource "openstack_networking_subnet_v2" "ext" {
  name            = "ext-subnet"
  network_id      = openstack_networking_network_v2.ext.id
  cidr            = "10.20.20.0/24"
  ip_version      = 4
  gateway_ip      = "10.20.20.1"
  enable_dhcp     = false
  allocation_pool {
    start = "10.20.20.100"
    end   = "10.20.20.200"
  }
}

# --- 내부 네트워크 (노드 VM용) ---
resource "openstack_networking_network_v2" "k8s" {
  name = "k8s-net"
}

resource "openstack_networking_subnet_v2" "k8s" {
  name            = "k8s-subnet"
  network_id      = openstack_networking_network_v2.k8s.id
  cidr            = "10.0.0.0/24"
  ip_version      = 4
  dns_nameservers = ["8.8.8.8"]
}

resource "openstack_networking_router_v2" "k8s" {
  name                = "k8s-router"
  external_network_id = openstack_networking_network_v2.ext.id

  # 외부 서브넷이 만들어진 뒤에 라우터를 만든다. external_network_id 만으로는 서브넷과의 순서가 보장되지 않아,
  # 라우터가 먼저 만들어지면 게이트웨이 포트가 IP 없이 생기고(external_fixed_ips: []) Floating IP 로 접속할 수 없다(2026-11-25 확인).
  depends_on = [openstack_networking_subnet_v2.ext]
}

resource "openstack_networking_router_interface_v2" "k8s" {
  router_id = openstack_networking_router_v2.k8s.id
  subnet_id = openstack_networking_subnet_v2.k8s.id
}

# --- flavor, 키페어, 노드 이미지 ---
resource "openstack_compute_flavor_v2" "node" {
  name      = "k8s-node"
  vcpus     = 4
  ram       = 8192
  disk      = 60
  is_public = true
}

resource "openstack_compute_keypair_v2" "node" {
  name       = "k8s-key"
  public_key = file(pathexpand("~/.ssh/k8s-node-key.pub"))
}

resource "openstack_images_image_v2" "node" {
  name             = "ubuntu-2404-kube-v1.36.6"
  local_file_path  = pathexpand("~/image-builder/images/capi/output/ubuntu-2404-kube-v1.36.6/ubuntu-2404-kube-v1.36.6")
  container_format = "bare"
  disk_format      = "qcow2"
  visibility       = "public"
}
