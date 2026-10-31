locals {
  project_name = "openinfra-lab"

  image_path = pathexpand("~/images/noble-server-cloudimg-amd64.img")

  nodes = {
    cp = {
      vcpu   = 4
      memory = 16384
      disk   = 60
      ip     = "192.168.100.10"
      mac    = "52:54:00:10:00:10"
    }

    ctrl-worker = {
      vcpu   = 16
      memory = 32768
      disk   = 120
      ip     = "192.168.100.11"
      mac    = "52:54:00:10:00:11"
    }

    compute-1 = {
      vcpu   = 10
      memory = 32768
      disk   = 80
      ip     = "192.168.100.21"
      mac    = "52:54:00:10:00:21"
    }

    compute-2 = {
      vcpu   = 10
      memory = 32768
      disk   = 80
      ip     = "192.168.100.22"
      mac    = "52:54:00:10:00:22"
    }
  }
}

# --------------------------------------------------
# Storage Pool
# --------------------------------------------------

resource "libvirt_pool" "openinfra" {
  name = local.project_name
  type = "dir"

  target = {
    path = "/var/lib/libvirt/images"
  }
}

# --------------------------------------------------
# Base Ubuntu Cloud Image
# --------------------------------------------------

resource "libvirt_volume" "ubuntu_base" {
  name = "ubuntu-24.04-base.qcow2"
  pool = libvirt_pool.openinfra.name

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = "file://${local.image_path}"
    }
  }
}

# --------------------------------------------------
# Network
# --------------------------------------------------

resource "libvirt_network" "openinfra" {
  name      = local.project_name
  autostart = true

  forward = {
    mode = "nat"
  }

  ips = [
    {
      address = "192.168.100.1"
      prefix  = 24

      dhcp = {
        enabled = true

        hosts = [
          for name, node in local.nodes : {
            name = name
            mac  = node.mac
            ip   = node.ip
          }
        ]
      }
    }
  ]
}

# --------------------------------------------------
# Node Volumes
# --------------------------------------------------

resource "libvirt_volume" "node_disk" {
  for_each = local.nodes

  name = "${each.key}.qcow2"
  pool = libvirt_pool.openinfra.name

  capacity = each.value.disk * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.ubuntu_base.path

    format = {
      type = "qcow2"
    }
  }
}

# --------------------------------------------------
# Cloud-init
# --------------------------------------------------

resource "libvirt_cloudinit_disk" "cloudinit" {
  for_each = local.nodes

  name = "${each.key}-cloudinit.iso"

  user_data = <<-EOF
    #cloud-config
    hostname: ${each.key}
    manage_etc_hosts: true

    users:
      - name: kit
        groups:
          - sudo
        shell: /bin/bash
        sudo:
          - ALL=(ALL) NOPASSWD:ALL
        ssh_authorized_keys:
          - ${trimspace(file(pathexpand("~/.ssh/id_vm_ed25519.pub")))}

    ssh_pwauth: false
    disable_root: true

    growpart:
      mode: auto
      devices:
        - /

    resize_rootfs: true
  EOF
}

# --------------------------------------------------
# Cloud-init Volumes
# --------------------------------------------------

resource "libvirt_volume" "cloudinit" {
  for_each = local.nodes

  name = "${each.key}-cloudinit.iso"
  pool = libvirt_pool.openinfra.name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = "file://${libvirt_cloudinit_disk.cloudinit[each.key].path}"
    }
  }
}

# --------------------------------------------------
# Virtual Machines
# --------------------------------------------------

resource "libvirt_domain" "node" {
  for_each = local.nodes

  name   = each.key
  type   = "kvm"
  memory = each.value.memory
  vcpu   = each.value.vcpu

  autostart = true

  disk = [
    {
      volume_id = libvirt_volume.node_disk[each.key].id
    }
  ]

  cdrom = [
    {
      volume_id = libvirt_volume.cloudinit[each.key].id
    }
  ]

  interfaces = [
    {
      network_id     = libvirt_network.openinfra.id
      mac            = each.value.mac
      wait_for_lease = true
    }
  ]

  console = [
    {
      type        = "pty"
      target_type = "serial"
      target_port = "0"
    }
  ]
}