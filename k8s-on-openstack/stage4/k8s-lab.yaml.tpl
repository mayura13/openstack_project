apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
kind: KubeadmConfigTemplate
metadata:
  name: @CLUSTER@-md-0
  namespace: default
spec:
  template:
    spec:
      joinConfiguration:
        nodeRegistration:
          kubeletExtraArgs:
          - name: cloud-provider
            value: external
          - name: provider-id
            value: openstack:///'{{ instance_id }}'
          name: '{{ local_hostname }}'
---
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: @CLUSTER@
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - @POD_CIDR@
    serviceDomain: cluster.local
  controlPlaneRef:
    apiGroup: controlplane.cluster.x-k8s.io
    kind: KubeadmControlPlane
    name: @CLUSTER@-control-plane
  infrastructureRef:
    apiGroup: infrastructure.cluster.x-k8s.io
    kind: OpenStackCluster
    name: @CLUSTER@
---
apiVersion: cluster.x-k8s.io/v1beta2
kind: MachineDeployment
metadata:
  name: @CLUSTER@-md-0
  namespace: default
spec:
  clusterName: @CLUSTER@
  replicas: @WORKERS@
  selector:
    matchLabels: null
  template:
    spec:
      bootstrap:
        configRef:
          apiGroup: bootstrap.cluster.x-k8s.io
          kind: KubeadmConfigTemplate
          name: @CLUSTER@-md-0
      clusterName: @CLUSTER@
      failureDomain: @AZ@
      infrastructureRef:
        apiGroup: infrastructure.cluster.x-k8s.io
        kind: OpenStackMachineTemplate
        name: @CLUSTER@-md-0
      version: @K8S_SEMVER@
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: KubeadmControlPlane
metadata:
  name: @CLUSTER@-control-plane
  namespace: default
spec:
  kubeadmConfigSpec:
    clusterConfiguration:
      controllerManager:
        extraArgs:
        - name: cloud-provider
          value: external
    initConfiguration:
      nodeRegistration:
        kubeletExtraArgs:
        - name: cloud-provider
          value: external
        - name: provider-id
          value: openstack:///'{{ instance_id }}'
        name: '{{ local_hostname }}'
    joinConfiguration:
      nodeRegistration:
        kubeletExtraArgs:
        - name: cloud-provider
          value: external
        - name: provider-id
          value: openstack:///'{{ instance_id }}'
        name: '{{ local_hostname }}'
  machineTemplate:
    spec:
      infrastructureRef:
        apiGroup: infrastructure.cluster.x-k8s.io
        kind: OpenStackMachineTemplate
        name: @CLUSTER@-control-plane
  replicas: @CP_REPLICAS@
  version: @K8S_SEMVER@
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: OpenStackCluster
metadata:
  name: @CLUSTER@
  namespace: default
spec:
  apiServer: {}
  externalNetwork:
    id: @EXT_NET_ID@
  identityRef:
    cloudName: @CLOUD_NAME@
    name: @SECRET_NAME@
  managedSecurityGroups:
    clusterNodesSecurityGroupRules:
    - description: Created by cluster-api-provider-openstack - BGP (calico)
      direction: ingress
      etherType: IPv4
      name: BGP (Calico)
      portRangeMax: 179
      portRangeMin: 179
      protocol: tcp
      remoteManagedGroups:
      - controlplane
      - worker
    - description: Created by cluster-api-provider-openstack - IP-in-IP (calico)
      direction: ingress
      etherType: IPv4
      name: IP-in-IP (calico)
      protocol: "4"
      remoteManagedGroups:
      - controlplane
      - worker
  network:
    filter:
      name: @NET@
  subnets:
  - filter:
      name: @SUBNET@
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: OpenStackMachineTemplate
metadata:
  name: @CLUSTER@-control-plane
  namespace: default
spec:
  template:
    spec:
      flavor:
        filter:
          name: @FLAVOR@
      image:
        filter:
          name: @IMAGE@
      sshKeyName: @KEYPAIR@
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: OpenStackMachineTemplate
metadata:
  name: @CLUSTER@-md-0
  namespace: default
spec:
  template:
    spec:
      flavor:
        filter:
          name: @FLAVOR@
      image:
        filter:
          name: @IMAGE@
      sshKeyName: @KEYPAIR@
