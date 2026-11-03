#!/usr/bin/env python3
# ==============================================================
# generate-inventory.py - Terraform 출력(JSON)으로 Ansible 인벤토리 2개를 만드는 파이썬 스크립트
# ==============================================================
# 입력 : {"cp": "192.168.100.10", "ctrl-worker": "...", ...} 형태의 JSON (Terraform output node_ips)
# 출력 : stage2용 인벤토리, stage3(Kubespray)용 인벤토리
#
# 왜 두 개를 만드나?
#   - stage2는 ansible.cfg가 접속 계정(kit)과 SSH 키를 알려 주므로 [all:vars] 가 필요 없습니다.
#   - stage3(Kubespray)는 자체 설정을 따로 쓰므로 접속 계정/SSH 키 정보를 인벤토리 안에 담습니다.
#
# 인벤토리 항목의 뜻
#   ansible_host : Ansible이 SSH로 접속할 주소
#   ip           : 그 노드가 Kubernetes 통신에 사용할 IP
#   access_ip    : 다른 노드가 이 노드에 접속할 때 사용할 IP
#
# 그룹 이름은 Kubespray가 정한 약속입니다.
#   kube_control_plane : 클러스터를 관리하는 노드     etcd : 클러스터 데이터 저장소
#   kube_node          : 일을 실행하는 노드            k8s_cluster:children : 위 그룹들을 묶은 상위 그룹
# 이 파일은 인벤토리를 "만들기만" 하며, 만들어진 인벤토리 파일을 직접 고치면 다음 실행 때 덮어써집니다.

import argparse
import json
from pathlib import Path


# 반드시 있어야 하는 노드 이름 4개 (3장 VM 구성표와 같음). 하나라도 없으면 아래에서 중단합니다.
REQUIRED_NODES = (
    "cp",
    "ctrl-worker",
    "compute-1",
    "compute-2",
)


# JSON 파일을 읽어서, 필수 노드가 모두 있는지 확인한 뒤 {노드 이름: IP} 딕셔너리를 돌려줍니다.
def load_nodes(path):
    with open(path, encoding="utf-8") as f:
        nodes = json.load(f)

    # 필수 노드 중 JSON에 없는 이름을 모읍니다. (리스트 컴프리헨션)
    missing = [name for name in REQUIRED_NODES if name not in nodes]
    if missing:
        raise SystemExit(
            "ERROR: missing node(s): " + ", ".join(missing)
        )

    return nodes


# 2단계(Ansible)용 인벤토리 내용을 문자열로 만듭니다.
# 아래 f 문자열(따옴표 3개로 감싼 여러 줄 문자열) 안의 {nodes["cp"]} 같은 부분은 실제 IP로 바뀝니다.
# (문자열 안쪽에는 주석을 넣을 수 없어서 설명을 여기에 모았습니다.)
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


# 3단계(Kubespray)용 인벤토리 내용을 만듭니다. 맨 아래 [all:vars] 가 모든 노드에 공통 적용됩니다.
#   ansible_user=kit                      : VM에 접속하는 계정 (cloud-init으로 만든 계정)
#   ansible_ssh_private_key_file=<키>     : 접속에 쓸 SSH 개인 키
#   StrictHostKeyChecking=no              : 처음 보는 서버의 지문 확인 질문을 건너뜀
#     (VM을 지우고 다시 만들 때마다 지문이 바뀌는 실습 환경이라 이렇게 두었습니다)
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


# 프로그램 시작점: 명령줄 옵션을 읽고, 두 인벤토리 파일을 씁니다.
def main():
    parser = argparse.ArgumentParser()
    # --input: Terraform 출력 JSON 파일 경로 (필수)
    parser.add_argument("--input", required=True)
    # --stage2-output / --stage3-output: 만들 파일의 경로 (필수)
    parser.add_argument("--stage2-output", required=True)
    parser.add_argument("--stage3-output", required=True)
    # --ssh-key: SSH 개인 키 경로. 생략하면 ~/.ssh/id_vm_ed25519 (stage1/prepare.sh가 만드는 키)
    parser.add_argument(
        "--ssh-key",
        default=str(Path.home() / ".ssh" / "id_vm_ed25519"),
    )
    args = parser.parse_args()

    # 입력 JSON을 읽고 필수 노드를 확인합니다.
    nodes = load_nodes(args.input)

    # stage2 인벤토리 파일 쓰기
    Path(args.stage2_output).write_text(
        stage2_inventory(nodes),
        encoding="utf-8",
    )

    # stage3 인벤토리 파일 쓰기
    Path(args.stage3_output).write_text(
        stage3_inventory(nodes, args.ssh_key),
        encoding="utf-8",
    )

    # 어떤 파일을 만들었는지 알려 줍니다.
    print(f"Generated: {args.stage2_output}")
    print(f"Generated: {args.stage3_output}")


# 이 파일을 직접 실행했을 때만 main() 을 실행합니다. (다른 파일이 import 했을 때는 실행되지 않음)
if __name__ == "__main__":
    main()
