# Kubespray Custom CNI Configuration with Private Helm Repository Authentication

## 1. Purpose

This document describes the `inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml` configuration used to deploy **Cilium** as a **custom CNI** through Kubespray by using a Helm chart stored in a private Nexus Helm repository.

This setup uses Kubespray’s `custom_cni` network plugin mode and deploys Cilium through Helm instead of applying static manifest files.

The private Helm repository requires authentication, so the Kubespray `custom_cni` role metadata must be modified to pass the Helm repository username and password to the `helm-apps` role.

> Recommended long-term approach: store the Helm repository password in **Ansible Vault**, HashiCorp Vault, or another secrets-management solution instead of keeping it as plain text in the inventory file.
> In this document, the username/password method is documented because this is the method currently used for this environment.

---

## 2. File Path

The inventory file is located at:

```text
inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml
```

This file defines the custom CNI deployment method, Helm repository details, Cilium chart version, and Cilium Helm values.

---

## 3. Required Kubespray Role Modification

By default, Kubespray’s `custom_cni` role may not pass repository authentication values to the Helm repository definition.

To support authenticated Helm repositories, modify the following file:

```text
roles/network_plugin/custom_cni/meta/main.yml
```

Create a backup first:

```bash
cp -a roles/network_plugin/custom_cni/meta/main.yml \
  roles/network_plugin/custom_cni/meta/main.yml.bak.$(date +%F-%H%M%S)
```

### Required Dependency Configuration

The dependency block should include `username` and `password` under the Helm repository definition:

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

### Why This Modification Is Required

The `helm-apps` role receives the repository configuration from this metadata file.

Without these two lines:

```yaml
username: "{{ custom_cni_chart_repository_username | default(omit) }}"
password: "{{ custom_cni_chart_repository_password | default(omit) }}"
```

Kubespray can define the Helm repository URL, but it cannot authenticate to a private Helm repository.

As a result, Helm chart installation may fail with authentication-related errors such as:

```text
401 Unauthorized
403 Forbidden
failed to fetch chart
repository not found
```

---

## 4. Important Maintenance Note

This is a direct modification to a Kubespray role file.

After upgrading Kubespray, replacing the Kubespray directory, or switching branches, this change may be lost.

After every Kubespray upgrade, verify the following file again:

```text
roles/network_plugin/custom_cni/meta/main.yml
```

Check that the repository block still contains:

```yaml
username: "{{ custom_cni_chart_repository_username | default(omit) }}"
password: "{{ custom_cni_chart_repository_password | default(omit) }}"
```

---

## 5. Custom CNI Configuration File

Create or update:

```text
inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml
```

Recommended sanitized version:

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
## Helm repository authentication
## NOTE:
## Plain-text credentials work, but this is not the safest method.
## Prefer Ansible Vault or another secret-management solution for production.
# custom_cni_chart_repository_username: ""
# custom_cni_chart_repository_password: ""
#
## Helm chart reference - path to the chart in the repository
# custom_cni_chart_ref: ""
#
## Helm chart version
# custom_cni_chart_version: ""
#
## Custom Helm values to be used for deployment
# custom_cni_chart_values: {}

## OPTION 2 EXAMPLE - Cilium deployed from private Nexus Helm repository

custom_cni_chart_namespace: kube-system
custom_cni_chart_release_name: "cilium"
custom_cni_chart_repository_name: "nexus"
custom_cni_chart_repository_url: "https://repo.shbbl.co/repository/helm/"
custom_cni_chart_repository_username: "helm"
custom_cni_chart_repository_password: "<REPLACE_WITH_HELM_REPOSITORY_PASSWORD>"
custom_cni_chart_ref: "nexus/cilium"
custom_cni_chart_version: "1.18.6"

custom_cni_chart_values:
  MTU: 0

  debug:
    enabled: false

  image:
    repository: quay.io/cilium/cilium
    tag: v1.18.6
    useDigest: false

  k8sServiceHost: "auto"
  k8sServicePort: "auto"

  ipv4:
    enabled: true

  ipv6:
    enabled: false

  l2announcements:
    enabled: false

  healthPort: 9879

  identityAllocationMode: crd

  tunnelProtocol: vxlan

  loadbalancer:
    mode: snat

  kubeProxyReplacement: true

  extraVolumes: []

  extraVolumeMounts: []

  extraArgs: []

  bpf:
    masquerade: false
    hostLegacyRouting: false
    monitorAggregation: medium
    preallocateMaps: false
    mapDynamicSizeRatio: 0.0025

  cni:
    exclusive: true
    logFile: /var/run/cilium/cilium-cni.log

  autoDirectNodeRoutes: false

  ipv4NativeRoutingCIDR:

  ipv6NativeRoutingCIDR:

  encryption:
    enabled: false

  bandwidthManager:
    enabled: false
    bbr: false

  ipMasqAgent:
    enabled: false

  hubble:
    enabled: true

    relay:
      enabled: true
      image:
        repository: quay.io/cilium/hubble-relay
        tag: v1.18.6
        useDigest: false

    ui:
      enabled: true

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
        enabled: false
        config:
          content:
            - name: all
              filePath: /var/run/cilium/hubble/events.log
              includeFilters: []
              excludeFilters: []
              fieldMask: []

  gatewayAPI:
    enabled: false

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
      enabled: true
    hostRoot: /run/cilium/cgroupv2

  operator:
    enabled: true
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

  enableIPv4Masquerade: true
  enableIPv6Masquerade: true

  hostFirewall:
    enabled: false

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

## 6. Important Notes About the Values File

### 6.1 Repository Credentials

This file currently uses:

```yaml
custom_cni_chart_repository_username: "helm"
custom_cni_chart_repository_password: "<REPLACE_WITH_HELM_REPOSITORY_PASSWORD>"
```

This allows Kubespray to authenticate to the Nexus Helm repository.

However, do not commit real passwords to Git.

Better options are:

```text
Ansible Vault
HashiCorp Vault
External Secrets Operator
Sealed Secrets
SOPS
CI/CD-provided environment variables
```

For this document, plain variables are documented because this is the selected method for this environment.

---

### 6.2 Typo Warning

The original values had this key in two places:

```yaml
repositry:
```

That is a typo.

It should be:

```yaml
repository:
```

Affected sections:

```yaml
certgen:
  image:
    repository: quay.io/cilium/certgen
```

and:

```yaml
envoy:
  image:
    repository: quay.io/cilium/cilium-envoy
```

If the typo remains, Helm may ignore the custom image repository value and use the chart default instead.

---

### 6.3 Boolean Style

Use lowercase YAML booleans:

```yaml
true
false
```

Instead of:

```yaml
True
False
```

Both may work depending on the parser, but lowercase booleans are safer and more consistent with Kubernetes and Helm values files.

---

## 7. Verify Helm Repository Access Manually

Before running Kubespray, verify that the Helm repository is reachable from the Kubespray machine.

```bash
helm repo add nexus https://repo.shbbl.co/repository/helm/ \
  --username helm \
  --password '<REPLACE_WITH_HELM_REPOSITORY_PASSWORD>'

helm repo update

helm search repo nexus/cilium --versions | head
```

Expected result:

```text
NAME            CHART VERSION   APP VERSION
nexus/cilium    1.18.6          1.18.6
```

If this fails, Kubespray will also fail during the CNI deployment stage.

---

## 8. Verify Kubespray Inventory Syntax

Run:

```bash
ansible-playbook -i inventory/shahkar/inventory.ini cluster.yml --syntax-check
```

Expected result:

```text
playbook: cluster.yml
```

If there is a YAML indentation issue, Ansible will fail before starting deployment.

---

## 9. Verify Custom CNI Variables Are Loaded

Run:

```bash
ansible -i inventory/shahkar/inventory.ini \
  groups['kube_control_plane'][0] \
  -m debug \
  -a 'var=custom_cni_chart_release_name'
```

If the above host-pattern syntax does not work in your shell, test against the first control-plane node directly:

```bash
ansible -i inventory/shahkar/inventory.ini <FIRST_CONTROL_PLANE_HOSTNAME> \
  -m debug \
  -a 'var=custom_cni_chart_release_name'
```

Expected value:

```text
cilium
```

Also verify the repository name:

```bash
ansible -i inventory/shahkar/inventory.ini <FIRST_CONTROL_PLANE_HOSTNAME> \
  -m debug \
  -a 'var=custom_cni_chart_repository_name'
```

Expected value:

```text
nexus
```

Do not print the password in logs unless you are troubleshooting in a secure terminal.

---

## 10. Deploy the Cluster

Run Kubespray normally:

```bash
ansible-playbook -i inventory/shahkar/inventory.ini cluster.yml -b
```

If the cluster already exists and only CNI-related changes are required, use the appropriate Kubespray recovery or upgrade playbook based on the current cluster state. Do not blindly rerun the full cluster deployment on production without checking impact.

---

## 11. Post-Deployment Verification

After deployment, verify Cilium pods:

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
```

Verify Cilium operator:

```bash
kubectl -n kube-system get pods -l io.cilium/app=operator -o wide
```

Verify Cilium status:

```bash
kubectl -n kube-system exec ds/cilium -- cilium status
```

Verify Cilium nodes:

```bash
kubectl get ciliumnodes
```

Verify Kubernetes nodes:

```bash
kubectl get nodes -o wide
```

Expected result:

```text
STATUS   ROLES           AGE   VERSION
Ready    control-plane   ...
Ready    worker          ...
```

---

## 12. Verify Hubble

Check Hubble Relay:

```bash
kubectl -n kube-system get pods -l k8s-app=hubble-relay -o wide
```

Check Hubble UI:

```bash
kubectl -n kube-system get pods -l k8s-app=hubble-ui -o wide
```

If needed, port-forward Hubble UI:

```bash
kubectl -n kube-system port-forward svc/hubble-ui 12000:80
```

Then open:

```text
http://127.0.0.1:12000
```

---

## 13. Common Failure Points

### 13.1 Helm Repository Authentication Failure

Possible error:

```text
401 Unauthorized
403 Forbidden
failed to fetch chart
```

Check:

```bash
helm repo add nexus https://repo.shbbl.co/repository/helm/ \
  --username helm \
  --password '<REPLACE_WITH_HELM_REPOSITORY_PASSWORD>'
```

If manual Helm login fails, fix Nexus credentials or repository permissions before running Kubespray again.

---

### 13.2 Missing Kubespray Role Modification

If `roles/network_plugin/custom_cni/meta/main.yml` does not include:

```yaml
username: "{{ custom_cni_chart_repository_username | default(omit) }}"
password: "{{ custom_cni_chart_repository_password | default(omit) }}"
```

Kubespray will not pass authentication to Helm.

Fix the role metadata and rerun the playbook.

---

### 13.3 Incorrect Chart Reference

The chart reference must match the Helm repository name and chart name:

```yaml
custom_cni_chart_repository_name: "nexus"
custom_cni_chart_ref: "nexus/cilium"
```

If the repository name changes, the chart reference must also change.

Example:

```yaml
custom_cni_chart_repository_name: "private-helm"
custom_cni_chart_ref: "private-helm/cilium"
```

---

### 13.4 Wrong Image Repository Key

Use:

```yaml
repository:
```

Do not use:

```yaml
repositry:
```

The typo may cause Helm to ignore the custom image path.

---

### 13.5 Cilium Pods Not Ready

Check Cilium pod logs:

```bash
kubectl -n kube-system logs -l k8s-app=cilium --tail=100
```

Check Cilium operator logs:

```bash
kubectl -n kube-system logs -l io.cilium/app=operator --tail=100
```

Check events:

```bash
kubectl -n kube-system get events --sort-by=.lastTimestamp | tail -50
```

---

## 14. Rollback

### 14.1 Restore Kubespray Role Metadata Backup

If the modification causes issues, restore the backup:

```bash
cp -a roles/network_plugin/custom_cni/meta/main.yml.bak.<DATE> \
  roles/network_plugin/custom_cni/meta/main.yml
```

Replace `<DATE>` with the actual backup suffix.

---

### 14.2 Remove Helm Repository from Local Helm Client

This only affects the local Helm client cache on the Kubespray machine:

```bash
helm repo remove nexus
```

---

### 14.3 Remove Cilium Helm Release

Only do this if you are intentionally removing Cilium from the cluster.

```bash
helm -n kube-system uninstall cilium
```

Warning: removing the active CNI from a running cluster can break pod networking. Do not run this on production unless you have a tested recovery plan.

---

## 15. Security Recommendation

The current method works, but it stores repository credentials as plain text:

```yaml
custom_cni_chart_repository_username: "helm"
custom_cni_chart_repository_password: "<REPLACE_WITH_HELM_REPOSITORY_PASSWORD>"
```

For a safer production design, encrypt the password with Ansible Vault:

```bash
ansible-vault encrypt_string '<REPLACE_WITH_HELM_REPOSITORY_PASSWORD>' \
  --name 'custom_cni_chart_repository_password'
```

Example output:

```yaml
custom_cni_chart_repository_password: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  ...
```

Then keep the encrypted value in:

```text
inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml
```

Run Kubespray with:

```bash
ansible-playbook -i inventory/shahkar/inventory.ini cluster.yml -b --ask-vault-pass
```

Or with a vault password file:

```bash
ansible-playbook -i inventory/shahkar/inventory.ini cluster.yml -b \
  --vault-password-file /secure/path/vault-pass.txt
```

This keeps the same variable name while avoiding plain-text secrets in Git.

---

## 16. Final Checklist

Before deployment, verify:

```text
[ ] network_plugin is set to custom_cni in the Kubespray inventory.
[ ] k8s-net-custom-cni.yml exists under inventory/shahkar/group_vars/k8s_cluster/.
[ ] The private Nexus Helm repository is reachable from the Kubespray machine.
[ ] Helm authentication works manually.
[ ] roles/network_plugin/custom_cni/meta/main.yml includes username and password fields.
[ ] The Cilium chart version exists in the Nexus Helm repository.
[ ] Image repositories are reachable from all Kubernetes nodes.
[ ] The password is not committed to Git in plain text unless this is explicitly accepted for the environment.
[ ] The original typo repositry has been corrected to repository.
[ ] Ansible syntax-check passes.
```
