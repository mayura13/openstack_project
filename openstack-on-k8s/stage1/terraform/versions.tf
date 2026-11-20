terraform {
  required_version = "= 1.15.9"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "= 0.9.9"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}