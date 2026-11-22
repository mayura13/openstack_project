#!/usr/bin/env python3
"""삭제 전후 OpenStack 상태 비교(검증 f). 개수가 아니라 이름과 ID 로 비교한다.
사용: compare.py <before_dir> <after_dir> <cluster_name>
출력 줄: OK|NG|WARN<TAB>제목<TAB>기준값<TAB>실제값<TAB>원인
종료 코드: 0(NG 없음), 1(NG 있음), 2(입력 오류)
"""
import json, os, re, sys

KINDS = [("server", "서버"), ("floating_ip", "Floating IP"), ("security_group", "보안 그룹"), ("port", "포트"),
         ("volume", "볼륨"), ("network", "네트워크"), ("subnet", "서브넷"), ("router", "라우터"),
         ("keypair", "키페어"), ("flavor", "flavor"), ("image", "이미지")]


def load(d, kind):
    p = os.path.join(d, kind + ".json")
    try:
        with open(p) as f:
            v = json.load(f)
        if not isinstance(v, list):
            return None
        if any(not isinstance(r, dict) for r in v):
            return None
        if any(not (r.get("ID") or r.get("Name")) for r in v):
            return None
        return v
    except Exception:
        return None


def ident(kind, r):
    return str(r.get("ID") or r.get("Name") or "")


def name(r):
    return str(r.get("Name") or "")


def main():
    if len(sys.argv) != 4:
        print("usage: compare.py before after cluster", file=sys.stderr); return 2
    bd, ad, cl = sys.argv[1:4]
    out = []
    def emit(level, title, want="", got="", why=""):
        out.append("\t".join([level, title, want, got, why]))

    before, after = {}, {}
    for k, _ in KINDS:
        before[k], after[k] = load(bd, k), load(ad, k)
        if before[k] is None or after[k] is None:
            emit("NG", "기록 파일 읽기: %s.json" % k, "있음", "없음 또는 형식 오류", "스냅샷 단계 실패")
    if any(before[k] is None or after[k] is None for k, _ in KINDS):
        print("\n".join(out)); return 1

    try:
        with open(os.path.join(bd, "api_fip.txt")) as f:
            fip_addr = f.read().strip()
        if not fip_addr:
            raise ValueError("Floating IP 주소가 비어 있음")

        with open(os.path.join(bd, "capo_ports.json")) as f:
            ports = json.load(f)
        if not isinstance(ports, list):
            raise ValueError("CAPO 포트 목록이 배열이 아님")
        if any(not isinstance(x, str) or not x for x in ports):
            raise ValueError("CAPO 포트 ID 형식 오류")
        capo_port_ids = set(ports)

    except (OSError, ValueError, TypeError) as e:
        emit("NG", "CAPO 삭제 전 기록 검증", "정상적인 Floating IP 및 포트 기록", str(e),
             "삭제 전 스냅샷을 확인해야 함")
        print("\n".join(out))
        return 1

    sg_re = re.compile(r"^k8s-cluster-.*-%s-secgroup-" % re.escape(cl))
    owned = {k: set() for k, _ in KINDS}
    for r in before["server"]:
        if name(r).startswith(cl + "-"): owned["server"].add(ident("server", r))
    for r in before["security_group"]:
        if sg_re.match(name(r)): owned["security_group"].add(ident("security_group", r))
    fip_port = ""
    for r in before["floating_ip"]:
        if fip_addr and str(r.get("Floating IP Address") or "") == fip_addr:
            owned["floating_ip"].add(ident("floating_ip", r)); fip_port = str(r.get("Port") or "")
    owned["port"] |= capo_port_ids
    if fip_port: owned["port"].add(fip_port)   # Floating IP 가 연결된 VM 포트(대개 이미 capo_ports 에 있다)
    # Floating IP 자체의 포트(device_owner=network:floatingip)는 Fixed IP 가 그 주소다. 서버에 붙은 포트가 아니라서 따로 찾아야 한다.
    if fip_addr:
        pat = re.compile(r"(?<![\d.])" + re.escape(fip_addr) + r"(?![\d.])")
        for r in before["port"]:
            if pat.search(str(r.get("Fixed IP Addresses") or "")):
                owned["port"].add(ident("port", r))

    if not owned["server"]:
        emit("NG", "삭제 전 기록에 클러스터 서버가 있음", "%s-* 서버 1개 이상" % cl, "0개", "삭제할 클러스터가 없었거나 기록이 잘못됨")
    if not fip_addr:
        emit("WARN", "API 서버 Floating IP 주소 기록", "있음", "없음", "Floating IP 정리 여부는 확인하지 못한다")

    # ① CAPO 자원은 사라져야 한다
    for k, label in KINDS:
        if not owned[k]:
            continue
        ids_after = {ident(k, r) for r in after[k]}
        left = sorted(owned[k] & ids_after)
        title = "CAPO 자원 정리됨: %s %d개" % (label, len(owned[k]))
        if left: emit("NG", title, "모두 사라짐", "남음: " + " ".join(x[:8] for x in left), "CAPO 가 정리하지 못했거나 아직 진행 중. 잠시 후 다시 확인")
        else: emit("OK", title)
    if cl:
        left_names = [name(r) for r in after["server"] if name(r).startswith(cl + "-")]
        if left_names: emit("NG", "이름이 %s- 로 시작하는 서버 없음" % cl, "0개", " ".join(left_names), "")

    # ② 그 밖의 자원(Terraform 공용 기반 등)은 같은 ID 로 남아야 한다
    for k, label in KINDS:
        keep = [r for r in before[k] if ident(k, r) not in owned[k]]
        ids_after = {ident(k, r) for r in after[k]}
        lost = [name(r) or ident(k, r) for r in keep if ident(k, r) not in ids_after]
        title = "보존됨: %s %d개" % (label, len(keep))
        if lost: emit("NG", title, "이름·ID 가 그대로 남음", "사라짐: " + " ".join(lost), "공용 기반 자원이 삭제됨. 4단계 주문서가 네트워크를 filter 로 지정했는지 확인")
        else: emit("OK", title)

    # ③ 새로 생긴 것
    for k, label in KINDS:
        ids_before = {ident(k, r) for r in before[k]}
        new = [name(r) or ident(k, r) for r in after[k] if ident(k, r) not in ids_before]
        if new: emit("WARN", "삭제 후 새로 생긴 %s" % label, "없음", " ".join(new), "다른 작업이 동시에 있었는지 확인")

    print("\n".join(out))
    return 1 if any(l.startswith("NG") for l in out) else 0


if __name__ == "__main__":
    raise SystemExit(main())
