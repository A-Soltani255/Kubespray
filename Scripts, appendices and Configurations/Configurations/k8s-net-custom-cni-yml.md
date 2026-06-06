# Kubespray Custom CNI Configuration with Cilium Helm Chart

## File Location

```text
inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml
```

## Purpose

This file configures Kubespray to deploy a custom Kubernetes CNI plugin.

In this environment, the custom CNI is **Cilium**, and it is deployed through **Kubespray custom CNI Helm chart mode** using a Helm chart stored in the internal Nexus Helm repository.

The selected deployment method is:

```text
OPTION 2 - Helm chart application
```

This means Kubespray deploys Cilium as a Helm release instead of applying static Kubernetes manifest files.

---

## Important Requirement

The default Kubespray `custom_cni` role does not pass Helm repository authentication variables unless the role dependency is modified.

Because the Helm repository requires authentication, the following variables are used:

```yaml
custom_cni_chart_repository_username
custom_cni_chart_repository_password
```

These variables must be added to the Helm repository definition inside:

```text
roles/network_plugin/custom_cni/meta/main.yml
```

---

## Required Kubespray Role Modification

Edit the following file:

```bash
vi roles/network_plugin/custom_cni/meta/main.yml
```

Update the `repositories` section under the `helm-apps` dependency so it supports `username` and `password`.

The expected configuration should look like this:

```yaml
dependencies:
  - role: helm-apps
    when:
      - inventory_hostname == groups['kube_control_plane'][0]
      - custom_cni_chart_release_name | length > 0
    environment:
      http_proxy: "{{ http_proxy | default('') }}"
      https_proxy: "{{ https_proxy | default('') }}"
    release_common_opts: {}
    releases:
      - name: "{{ custom_cni_chart_release_name }}"
        namespace: "{{ custom_cni_chart_namespace }}"
        chart_ref: "{{ custom_cni_chart_ref }}"
        chart_version: "{{ custom_cni_chart_version }}"
        wait: true
        values: "{{ custom_cni_chart_values }}"
    repositories:
      - name: "{{ custom_cni_chart_repository_name }}"
        url: "{{ custom_cni_chart_repository_url }}"
        username: "{{ custom_cni_chart_repository_username | default(omit) }}"
        password: "{{ custom_cni_chart_repository_password | default(omit) }}"
```

### Why This Change Is Needed

Kubespray passes Helm repository information to the internal `helm-apps` role.

Without this modification, only the repository name and URL are passed. If the Helm repository requires authentication, Helm cannot pull the chart from Nexus.

These two lines allow authenticated Helm repository access:

```yaml
username: "{{ custom_cni_chart_repository_username | default(omit) }}"
password: "{{ custom_cni_chart_repository_password | default(omit) }}"
```

The `default(omit)` filter means:

* If the variable is defined, Kubespray passes it to the Helm repository configuration.
* If the variable is not defined, Ansible omits the field completely.
* This keeps the configuration backward-compatible with unauthenticated Helm repositories.

---

## Security Recommendation

The configuration below uses a plaintext username and password inside the inventory file.

This works, but it is not the safest method.

The recommended production approach is to store sensitive variables using **Ansible Vault** instead of plain YAML.

Example recommended Vault-based approach:

```bash
ansible-vault create inventory/shahkar/group_vars/k8s_cluster/vault.yml
```

Example Vault content:

```yaml
custom_cni_chart_repository_username: "admin"
custom_cni_chart_repository_password: "<helm_repository_password>"
```

Then run Kubespray with:

```bash
ansible-playbook -i inventory/shahkar/inventory.ini cluster.yml --ask-vault-pass
```

However, this document follows the current implementation, where the Helm repository username and password are defined directly in:

```text
inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml
```

---

# Custom CNI Configuration

```yaml
---
# custom_cni network plugin configuration
# There are two deployment options to choose from, select one

## OPTION 1 - Static manifest files
## With this option, referred manifest file will be deployed
## as if the `kubectl apply -f` method was used with it.
#
## List of Kubernetes resource manifest files
## See tests/files/custom_cni/README.md for example
# custom_cni_manifests: []

## OPTION 1 EXAMPLE - Cilium static manifests in Kubespray tree
# custom_cni_manifests:
#   - "{{ playbook_dir }}/../tests/files/custom_cni/cilium.yaml"

## OPTION 2 - Helm chart application
## This allows the CNI backend to be deployed to Kubespray cluster
## as common Helm application.
#
## Helm release name - how the local instance of deployed chart will be named
# custom_cni_chart_release_name: ""
#
## Kubernetes namespace to deploy into
# custom_cni_chart_namespace: "kube-system"
#
## Helm repository name - how the local record of Helm repository will be named
# custom_cni_chart_repository_name: ""
#
## Helm repository URL
# custom_cni_chart_repository_url: ""
#
## Helm chart reference - path to the chart in the repository
# custom_cni_chart_ref: ""
#
## Helm chart version
# custom_cni_chart_version: ""
#
## Custom Helm values to be used for deployment
# custom_cni_chart_values: {}

## OPTION 2 EXAMPLE - Cilium deployed from official public Helm chart
# custom_cni_chart_namespace: kube-system
# custom_cni_chart_release_name: cilium
# custom_cni_chart_repository_name: cilium
# custom_cni_chart_repository_url: https://helm.cilium.io
# custom_cni_chart_ref: cilium/cilium
# custom_cni_chart_version: <chart version> (e.g.: 1.14.3)
# custom_cni_chart_values:
#   cluster:
#     name: "cilium-demo"

custom_cni_chart_namespace: kube-system
custom_cni_chart_release_name: "cilium"
custom_cni_chart_repository_name: "nexus"
custom_cni_chart_repository_url: "https://repo.shbbl.co/repository/helm/"
custom_cni_chart_repository_username: "admin"
custom_cni_chart_repository_password: "<helm_repository_password>"
custom_cni_chart_ref: "nexus/cilium"
custom_cni_chart_version: "1.18.6"

custom_cni_chart_values:
  MTU: 0

  debug:
    enabled: False

  image:
    repository: quay.io/cilium/cilium
    tag: v1.18.6
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

  kubeProxyReplacement: True

  extraVolumes: []

  extraVolumeMounts: []

  extraArgs: []

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
        tag: v1.18.6
        useDigest: false

    ui:
      enabled: True

      backend:
        image:
          repository: quay.io/cilium/hubble-ui-backend
          tag: v0.13.3
          useDigest: false

      frontend:
        image:
          repository: quay.io/cilium/hubble-ui
          tag: v0.13.3
          useDigest: false

    metrics:
      enabled:
        - dns
        - drop
        - tcp
        - flow
        - icmp
        - http

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

  operator:
    enabled: True
    image:
      repository: quay.io/cilium/operator
      tag: v1.18.6
      genericDigest: "sha256:a5c7859195de9653ec3a23f1303ec7eca7c79a380428037a1bdeacf23187f051"
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
      tag: v0.2.4
      useDigest: false

  envoy:
    image:
      repository: quay.io/cilium/cilium-envoy
      tag: v1.34.10-1762597008-ff7ae7d623be00078865cff1b0672cc5d9bfc6d5
      useDigest: false
```

---

# Variable Explanation

## Helm Deployment Variables

| Variable                               | Description                                               |
| -------------------------------------- | --------------------------------------------------------- |
| `custom_cni_chart_namespace`           | Kubernetes namespace where Cilium will be deployed.       |
| `custom_cni_chart_release_name`        | Helm release name. In this setup, it is `cilium`.         |
| `custom_cni_chart_repository_name`     | Local Helm repository name. In this setup, it is `nexus`. |
| `custom_cni_chart_repository_url`      | Nexus Helm repository URL.                                |
| `custom_cni_chart_repository_username` | Username used to authenticate to the Helm repository.     |
| `custom_cni_chart_repository_password` | Password used to authenticate to the Helm repository.     |
| `custom_cni_chart_ref`                 | Helm chart reference. In this setup, `nexus/cilium`.      |
| `custom_cni_chart_version`             | Cilium Helm chart version.                                |

---

## Cilium Image Configuration

```yaml
image:
  repository: quay.io/cilium/cilium
  tag: v1.18.6
  useDigest: false
```

This defines the main Cilium agent image.

The image is pulled from:

```text
quay.io/cilium/cilium:v1.18.6
```

In an offline or restricted environment, this image must already exist in the allowed registry or be reachable through the configured image pull path.

---

## Kubernetes API Access

```yaml
k8sServiceHost: "auto"
k8sServicePort: "auto"
```

Cilium automatically detects the Kubernetes API server endpoint.

This is useful in Kubespray deployments because the API endpoint may be managed through the Kubernetes service or through a load balancer, depending on the cluster configuration.

---

## IP Version Settings

```yaml
ipv4:
  enabled: True

ipv6:
  enabled: False
```

IPv4 is enabled and IPv6 is disabled.

Although IPv6 pool values are present later in the file, IPv6 is not active because:

```yaml
ipv6:
  enabled: False
```

---

## Tunnel Mode

```yaml
tunnelProtocol: vxlan
```

Cilium uses VXLAN encapsulation for pod-to-pod traffic between nodes.

This is useful when the underlay network does not directly route pod CIDRs between Kubernetes nodes.

---

## Load Balancer Mode

```yaml
loadbalancer:
  mode: snat
```

Cilium load balancing uses SNAT mode.

This means return traffic is handled through source NAT, which is usually simpler to operate when the external network does not have routes back to pod IPs.

---

## kube-proxy Replacement

```yaml
kubeProxyReplacement: True
```

Cilium replaces kube-proxy functionality using eBPF.

With this setting enabled, Kubernetes service handling is performed by Cilium instead of kube-proxy.

Important notes:

* kube-proxy should not be deployed or should be disabled by Kubespray.
* Cilium must be healthy before relying on Kubernetes service networking.
* Wrong kube-proxy replacement settings can break service connectivity.

---

## BPF Settings

```yaml
bpf:
  masquerade: False
  hostLegacyRouting: False
  monitorAggregation: medium
  preallocateMaps: False
  mapDynamicSizeRatio: 0.0025
```

These settings control Cilium eBPF behavior.

| Setting               | Description                                      |
| --------------------- | ------------------------------------------------ |
| `masquerade`          | Controls BPF-based masquerading.                 |
| `hostLegacyRouting`   | Controls whether legacy host routing is used.    |
| `monitorAggregation`  | Controls Cilium monitor event aggregation level. |
| `preallocateMaps`     | Controls whether BPF maps are preallocated.      |
| `mapDynamicSizeRatio` | Controls dynamic BPF map sizing.                 |

---

## CNI Settings

```yaml
cni:
  exclusive: True
  logFile: /var/run/cilium/cilium-cni.log
```

`exclusive: True` means Cilium takes ownership of CNI configuration on the nodes.

This is the expected setting when Cilium is the only CNI plugin for the cluster.

The CNI log file is stored at:

```text
/var/run/cilium/cilium-cni.log
```

---

## IPAM Configuration

```yaml
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.233.64.0/18
    clusterPoolIPv4MaskSize: 24
```

Cilium uses cluster-pool IPAM mode.

The pod CIDR pool is:

```text
10.233.64.0/18
```

Each node receives a `/24` pod CIDR from this pool.

Important:

This CIDR must match the Kubernetes/Kubespray pod network design. Do not change it after deployment unless you are intentionally rebuilding or carefully migrating the cluster network.

---

## Hubble Configuration

```yaml
hubble:
  enabled: True
  relay:
    enabled: True
  ui:
    enabled: True
```

Hubble is enabled for Cilium observability.

This deploys:

* Hubble Relay
* Hubble UI
* Hubble metrics

Enabled Hubble metrics:

```yaml
metrics:
  enabled:
    - dns
    - drop
    - tcp
    - flow
    - icmp
    - http
```

These metrics help observe network flows, dropped packets, DNS traffic, TCP traffic, ICMP traffic, and HTTP traffic.

---

## Cilium Operator

```yaml
operator:
  enabled: True
  replicas: 2
```

The Cilium operator is enabled with two replicas.

This provides better availability than a single operator replica.

The operator image is:

```text
quay.io/cilium/operator:v1.18.6
```

---

## Cluster Identity

```yaml
cluster:
  id: 0
  name: default
```

This defines the Cilium cluster identity.

For a single cluster, this is acceptable.

For multi-cluster or ClusterMesh environments, use a unique cluster ID and cluster name.

---

# Validation Commands

## Validate YAML Syntax

From the Kubespray root directory:

```bash
python3 - <<'PY'
import yaml
from pathlib import Path

file_path = Path("inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml")

with file_path.open() as f:
    yaml.safe_load(f)

print(f"YAML syntax is valid: {file_path}")
PY
```

Expected output:

```text
YAML syntax is valid: inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml
```

---

## Verify the Custom CNI Variables

```bash
grep -nE 'custom_cni_chart_(namespace|release_name|repository_name|repository_url|repository_username|repository_password|ref|version)' \
  inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml
```

This confirms that the required custom CNI Helm variables are defined.

---

## Verify the Role Modification

```bash
grep -nE 'username|password|custom_cni_chart_repository' \
  roles/network_plugin/custom_cni/meta/main.yml
```

Expected result should include:

```yaml
username: "{{ custom_cni_chart_repository_username | default(omit) }}"
password: "{{ custom_cni_chart_repository_password | default(omit) }}"
```

---

## Run Kubespray Syntax Check

```bash
ansible-playbook -i inventory/shahkar/inventory.ini cluster.yml --syntax-check
```

This checks Ansible syntax before applying the deployment.

If Ansible Vault is used, run:

```bash
ansible-playbook -i inventory/shahkar/inventory.ini cluster.yml --syntax-check --ask-vault-pass
```

---

# Deployment Command

Run Kubespray from the Kubespray root directory:

```bash
ansible-playbook -i inventory/shahkar/inventory.ini cluster.yml
```

If privilege escalation requires a password:

```bash
ansible-playbook -i inventory/shahkar/inventory.ini cluster.yml --ask-become-pass
```

If Ansible Vault is used:

```bash
ansible-playbook -i inventory/shahkar/inventory.ini cluster.yml --ask-vault-pass
```

If both become password and Vault password are required:

```bash
ansible-playbook -i inventory/shahkar/inventory.ini cluster.yml --ask-become-pass --ask-vault-pass
```

---

# Post-Deployment Verification

## Check Cilium Pods

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
```

Expected result:

```text
cilium-xxxxx   1/1   Running
```

There should be one Cilium agent pod per Kubernetes node.

---

## Check Cilium Operator

```bash
kubectl -n kube-system get pods -l name=cilium-operator -o wide
```

Expected result:

```text
cilium-operator-xxxxx   1/1   Running
cilium-operator-yyyyy   1/1   Running
```

---

## Check Cilium Status

```bash
kubectl -n kube-system exec ds/cilium -- cilium status
```

Expected important fields:

```text
KVStore:                 Ok
Kubernetes:              Ok
Kubernetes APIs:         Ok
Cilium:                  Ok
Operator:                Ok
```

---

## Check Kubernetes Nodes

```bash
kubectl get nodes -o wide
```

Expected result:

```text
STATUS   ROLES           AGE   VERSION
Ready    control-plane   ...
Ready    worker          ...
```

All nodes should be in `Ready` state.

---

## Check Cilium CNI Log on a Node

Run this on a Kubernetes node:

```bash
sudo tail -n 100 /var/run/cilium/cilium-cni.log
```

This helps troubleshoot CNI plugin execution issues during pod creation.

---

## Check Hubble Components

```bash
kubectl -n kube-system get pods | grep hubble
```

Expected components:

```text
hubble-relay
hubble-ui
```

---

# Troubleshooting

## Helm Repository Authentication Failure

Possible error:

```text
failed to fetch chart from repository
401 Unauthorized
```

Check:

```bash
grep -nE 'custom_cni_chart_repository_username|custom_cni_chart_repository_password' \
  inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml
```

Also verify the role modification exists:

```bash
grep -nE 'username|password' roles/network_plugin/custom_cni/meta/main.yml
```

---

## Helm Repository Not Reachable

Test from the Kubespray machine:

```bash
curl -k -I https://repo.shbbl.co/repository/helm/
```

Expected result should be an HTTP response from Nexus.

If authentication is required:

```bash
curl -k -u 'admin:<helm_repository_password>' -I https://repo.shbbl.co/repository/helm/
```

---

## Cilium Pods Not Running

Check pod status:

```bash
kubectl -n kube-system get pods -o wide
```

Check events:

```bash
kubectl -n kube-system describe pod <cilium-pod-name>
```

Check logs:

```bash
kubectl -n kube-system logs <cilium-pod-name>
```

---

## Nodes Are Not Ready

Check node condition:

```bash
kubectl describe node <node-name>
```

Common causes:

* Cilium pods are not running.
* CNI configuration was not installed.
* Pod CIDR is wrong.
* Required kernel features are missing.
* Firewall is blocking VXLAN or Kubernetes API traffic.
* kube-proxy replacement setting does not match the cluster design.

---

# Rollback

## Roll Back the Role Modification

If the Helm repository authentication change causes problems, remove these two lines from:

```text
roles/network_plugin/custom_cni/meta/main.yml
```

```yaml
username: "{{ custom_cni_chart_repository_username | default(omit) }}"
password: "{{ custom_cni_chart_repository_password | default(omit) }}"
```

This returns the role to unauthenticated Helm repository behavior.

---

## Roll Back the Inventory File

Restore the previous version of:

```text
inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml
```

If Git is used:

```bash
git checkout -- inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml
```

If the Kubespray role file is also tracked by Git:

```bash
git checkout -- roles/network_plugin/custom_cni/meta/main.yml
```

---

## Remove Failed Cilium Helm Release Manually

Only do this if Kubespray deployment failed and left a broken Helm release behind.

```bash
helm -n kube-system list
```

If the failed release exists:

```bash
helm -n kube-system uninstall cilium
```

Then verify:

```bash
kubectl -n kube-system get pods | grep cilium
```

Be careful: removing Cilium from an active cluster can break pod networking.

---

# Operational Notes

* Keep `custom_cni_chart_version` aligned with the Cilium image tag.
* Confirm the Cilium chart exists in the Nexus Helm repository before running Kubespray.
* Confirm all required Cilium images are available to the cluster.
* Do not change the pod CIDR after cluster deployment unless you are rebuilding or performing a planned migration.
* Avoid committing real repository credentials to Git.
* Prefer Ansible Vault for long-term credential management.
* After modifying files under `roles/`, document the change clearly because future Kubespray upgrades may overwrite it.

---

# Summary

This configuration deploys Cilium as the custom CNI for the Shahkar Kubespray cluster using Helm.

The Helm chart is pulled from the internal Nexus Helm repository:

```text
https://repo.shbbl.co/repository/helm/
```

Because the repository requires authentication, the Kubespray `custom_cni` role must be modified to pass:

```yaml
custom_cni_chart_repository_username
custom_cni_chart_repository_password
```

The current document uses plaintext variables for compatibility with the existing deployment method, but the recommended secure approach is to move the credentials into Ansible Vault.
