#!/usr/bin/env python3

import argparse
import json
from pathlib import Path


REQUIRED_NODES = (
    "cp",
    "ctrl-worker",
    "compute-1",
    "compute-2",
)


def load_nodes(path):
    with open(path, encoding="utf-8") as f:
        nodes = json.load(f)

    missing = [name for name in REQUIRED_NODES if name not in nodes]
    if missing:
        raise SystemExit(
            "ERROR: missing node(s): " + ", ".join(missing)
        )

    return nodes


def stage2_inventory(nodes):
    return f"""[all]
cp ansible_host={nodes["cp"]} ip={nodes["cp"]} access_ip={nodes["cp"]}
ctrl-worker ansible_host={nodes["ctrl-worker"]} ip={nodes["ctrl-worker"]} access_ip={nodes["ctrl-worker"]}
compute-1 ansible_host={nodes["compute-1"]} ip={nodes["compute-1"]} access_ip={nodes["compute-1"]}
compute-2 ansible_host={nodes["compute-2"]} ip={nodes["compute-2"]} access_ip={nodes["compute-2"]}

[kube_control_plane]
cp

[etcd]
cp

[kube_node]
ctrl-worker
compute-1
compute-2

[k8s_cluster:children]
kube_control_plane
kube_node
"""


def stage3_inventory(nodes, ssh_key):
    return f"""[kube_control_plane]
cp ansible_host={nodes["cp"]} ip={nodes["cp"]} access_ip={nodes["cp"]}

[etcd]
cp

[kube_node]
ctrl-worker ansible_host={nodes["ctrl-worker"]} ip={nodes["ctrl-worker"]} access_ip={nodes["ctrl-worker"]}
compute-1 ansible_host={nodes["compute-1"]} ip={nodes["compute-1"]} access_ip={nodes["compute-1"]}
compute-2 ansible_host={nodes["compute-2"]} ip={nodes["compute-2"]} access_ip={nodes["compute-2"]}

[k8s_cluster:children]
kube_control_plane
kube_node

[all:vars]
ansible_user=kit
ansible_ssh_private_key_file={ssh_key}
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--stage2-output", required=True)
    parser.add_argument("--stage3-output", required=True)
    parser.add_argument(
        "--ssh-key",
        default=str(Path.home() / ".ssh" / "id_vm_ed25519"),
    )
    args = parser.parse_args()

    nodes = load_nodes(args.input)

    Path(args.stage2_output).write_text(
        stage2_inventory(nodes),
        encoding="utf-8",
    )

    Path(args.stage3_output).write_text(
        stage3_inventory(nodes, args.ssh_key),
        encoding="utf-8",
    )

    print(f"Generated: {args.stage2_output}")
    print(f"Generated: {args.stage3_output}")


if __name__ == "__main__":
    main()
