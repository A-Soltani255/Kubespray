### Custom CNI via Helm — `inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml`

*(This is why `kube_network_plugin: custom_cni` is set in `inventory/shahkar/group_vars/k8s_cluster/k8s-cluster.yml`.)*

We use Kubespray’s **custom CNI** path to deploy **Cilium** from the **Nexus Helm repo** in our air-gapped LAN. Image pulls still reference `quay.io` etc., but `containerd` rewrites them to your four Nexus mirrors (`:5000/:5001/:5002/:5003`) per your hosts.toml. 

### Do on the Kubespray host

```bash
# Create the group_vars file (inventory: shahkar)
sudo install -d -m 0755 inventory/shahkar/group_vars/k8s_cluster

# Write k8s-net-custom-cni.yml (uses your values; see note about repository URL)
sudo tee inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml >/dev/null <<'YAML'
---
# custom_cni network plugin configuration
# OPTION 2 - Deploy Cilium via Helm from Nexus

## Helm chart application (Cilium)
custom_cni_chart_namespace: kube-system
custom_cni_chart_release_name: "cilium"
custom_cni_chart_repository_name: "nexus"

# NOTE: keep this on your Nexus IP for consistency with the rest of the doc.
# (You had 192.168.59.29 earlier; the current doc uses 192.168.154.133.)
custom_cni_chart_repository_url: "http://192.168.154.133:8081/repository/helm/"

custom_cni_chart_ref: "nexus/cilium"
custom_cni_chart_version: "1.17.3"

custom_cni_chart_values:
  MTU: 0
  debug:
    enabled: False

  image:
    repository: quay.io/cilium/cilium
    tag: v1.17.3
    useDigest: false

  k8sServiceHost: "auto"
  k8sServicePort: "auto"

  ipv4:
    enabled: True
  ipv6:
    enabled: False

  l2announcements:
    enabled: False

  healthPort: 9879
  identityAllocationMode: crd
  tunnelProtocol: vxlan

  loadbalancer:
    mode: snat

  # If kube-proxy stays enabled (your baseline), strict replacement can be risky.
  # Keep True if you know the implications; otherwise consider "partial".
  kubeProxyReplacement: True

  bpf:
    masquerade: False
    hostLegacyRouting: False
    monitorAggregation: medium
    preallocateMaps: False
    mapDynamicSizeRatio: 0.0025

  cni:
    exclusive: True
    logFile: /var/run/cilium/cilium-cni.log

  autoDirectNodeRoutes: False

  ipv4NativeRoutingCIDR:
  ipv6NativeRoutingCIDR:

  encryption:
    enabled: False

  bandwidthManager:
    enabled: False
    bbr: False

  ipMasqAgent:
    enabled: False

  hubble:
    enabled: True
    relay:
      enabled: True
      image:
        repository: quay.io/cilium/hubble-relay
        tag: v1.17.3
        useDigest: false
    ui:
      enabled: True
      backend:
        image:
          repository: quay.io/cilium/hubble-ui-backend
          tag: v0.13.2
          useDigest: false
      frontend:
        image:
          repository: quay.io/cilium/hubble-ui
          tag: v0.13.2
          useDigest: false
    metrics:
      enabled: ['dns', 'drop', 'tcp', 'flow', 'icmp', 'http']
    export:
      fileMaxBackups: 5
      fileMaxSizeMb: 10
      dynamic:
        enabled: False
        config:
          content:
            - excludeFilters: []
              fieldMask: []
              filePath: /var/run/cilium/hubble/events.log
              includeFilters: []
              name: all

  gatewayAPI:
    enabled: False

  ipam:
    mode: cluster-pool
    operator:
      clusterPoolIPv4PodCIDRList:
        - 10.233.64.0/18
      clusterPoolIPv4MaskSize: 24
      clusterPoolIPv6PodCIDRList:
        - fd85:ee78:d8a6:8607::1:0000/112
      clusterPoolIPv6MaskSize: 120

  cgroup:
    autoMount:
      enabled: True
    hostRoot: /run/cilium/cgroupv2

  extraVolumes:
    - name: lib-modules
      hostPath:
        path: /lib/modules
        type: Directory
  extraVolumeMounts:
    - name: lib-modules
      mountPath: /lib/modules
      readOnly: true

  operator:
    enabled: True
    image:
      repository: quay.io/cilium/operator-generic
      tag: v1.17.3
      useDigest: false
    replicas: 2
    extraArgs: []
    extraVolumes: []
    extraVolumeMounts: []
    tolerations:
      - operator: Exists

  cluster:
    id: 0
    name: default

  enableIPv4Masquerade: True
  enableIPv6Masquerade: True

  hostFirewall:
    enabled: False

  certgen:
    image:
      repository: quay.io/cilium/certgen
      tag: v0.2.1
      useDigest: false

  envoy:
    image:
      repository: quay.io/cilium/cilium-envoy
      tag: v1.32.5-1744305768-f9ddca7dcd91f7ca25a505560e655c47d3dec2cf
      useDigest: false
YAML

# Ensure the network plugin is set to custom_cni (you already said it is)
# This is idempotent and harmless if it's already correct.
sudo sed -i 's/^\(\s*kube_network_plugin:\s*\).*/\1custom_cni/' \
  inventory/shahkar/group_vars/k8s_cluster/k8s-cluster.yml

# Converge (new cluster): Kubespray will pick up group_vars automatically
ansible-playbook -i inventory/shahkar/hosts.yaml -b cluster.yml -vv
```

### Token-by-token breakdown & safety notes

* `install -d -m 0755 …/k8s_cluster`
  Creates the target dir with sane permissions.
* `tee … k8s-net-custom-cni.yml <<'YAML'`
  Writes the file atomically. Single-quoted heredoc prevents shell expansion inside YAML.
  **Consistency fix:** `custom_cni_chart_repository_url` uses **`192.168.154.133`** (your Nexus elsewhere in the doc), not `192.168.59.29`. If you truly host Helm on another IP, mirror that everywhere (containerd mirrors, examples, scripts). 
* `kubeProxyReplacement: True`
  With **kube-proxy enabled** (your baseline lists it), strict replacement can conflict on datapath. Consider `"partial"` if you see iptables/ipvs oddities under load; otherwise disable kube-proxy cluster-wide before using strict replacement.
* **Images still reference `quay.io`/`registry.k8s.io`**
  That’s correct; your **containerd hosts.toml** maps these to Nexus (`:5002`, `:5001`, etc.), so no need to retag inside Helm values. 
* `sed -i … kube_network_plugin: custom_cni`
  Makes the intent explicit in `k8s-cluster.yml`: *we are using the custom CNI hook, deployed via Helm from Nexus*.
* `ansible-playbook … cluster.yml`
  Fresh build: safe. **Do not** switch CNIs on an existing busy cluster; treat CNI changes as a rebuild unless you have a tested migration plan.
