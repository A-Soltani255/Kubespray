
# Air‑Gapped Kubernetes with Kubespray — Complete Instruction
_Last updated: 2025-08-25 14:50:51 UTC_


## Introduction:
This document documents—end-to-end—how to build and operate a Kubernetes 1.33.3 cluster on Rocky Linux 9 in a fully air-gapped (offline) environment using Kubespray and Sonatype Nexus. It is written from a real, working deployment and includes all practical details you need to reproduce the outcome: mirroring RPMs and container images, staging Kubernetes binaries, teaching containerd to use your HTTP registry mirrors, pinning versions, disabling non-essential add-ons, and validating the final cluster.

The environment used throughout:
- Control planes: master1 (`192.168.154.131`) master2 (`192.168.154.132`) master3 (`192.168.154.134`)
- Workers: worker1 (`192.168.154.135`), worker2 (`192.168.154.136`)
- Build/automation: kubespray (`192.168.154.137`) — also serves offline files over HTTP (`:8080`)
- Artifact hub: nexus (`192.168.154.133`) — YUM (hosted) for RPMs and Docker (hosted) registries on :5000 :5001 :5002 :5003 for images

> Design choices (and why):
>- Air-gapped: reduces supply-chain risk, satisfies compliance, and guarantees repeatable builds by eliminating “latest from the Internet”.
>- Kubespray: declarative, idempotent, and inventory-driven automation built on Ansible; easier to audit than ad-hoc kubeadm scripts.
>- containerd (+ nerdctl/ctr): the CNCF-blessed container runtime with clear, file-driven mirror and auth configuration.
>- Calico (KDD mode): mature, simple underlay/overlay networking; no external datastore; offline artifacts are small and easy to mirror.
>- Core components only: apiserver, controller-manager, scheduler, etcd, kube-proxy, CoreDNS, Calico node/controllers. We explicitly disable nginx-proxy, dns-autoscaler, metrics-server, Helm, etc., for a minimal, production-friendly baseline.

### What you will do (nature of the work)

#### 1. Prepare artifacts online (once, on an Internet-connected Rocky 9 box):
- Mirror OS RPMs (BaseOS/AppStream/EPEL/Docker CE) with reposync and archive them.
- Clone Kubespray, pre-download pip wheels for offline installs, and generate lists of required Kubernetes binaries and container images using contrib/offline.
- Pull and save all container images and gather all binaries (kubeadm/kubelet/kubectl, containerd/runc/nerdctl, crictl, CNI, etcd, Helm, Calico).
#### 2. Seed Nexus in the offline LAN:
- Load the archived RPMs into a YUM (hosted) repo (preserving repodata/).
- Stand up a Docker (hosted) registry on `192.168.154.133:5000`, load all images, retag them under the required mirror namespaces, and push.
- Ensure every offline node has a local.repo pointing to Nexus and can dnf update without Internet.
#### 3. Stage files on the Kubespray VM and serve over HTTP:
- Place the offline binaries under /srv/offline-files/ following the exact paths Kubespray expects.
- Serve them with a tiny HTTP server (python3 -m http.server 8080).
#### 4. Automate the cluster build with Kubespray:
- Prepare an inventory for master1, worker1, worker2.
- Provide group_vars for offline, k8s-cluster, and containerd (mirrors, insecure HTTP, optional auth).
- Run cluster.yml once to converge the cluster.
#### 5. Verify and lock in:
- Confirm nodes/Pods, image pull behavior (HTTP mirrors), and add-on minimalism.
- Capture the final configs and artifacts for audit and future rebuilds.

This is infrastructure as code. Every input (versions, URLs, checksums, mirrors) is in version-controlled YAML, and the output is deterministic when rerun against the same artifacts.


### Why Kubespray?
Kubespray is a mature, upstream-maintained collection of Ansible playbooks and roles for building vanilla Kubernetes. Its advantages are especially compelling for air-gapped builds:

#### 1. Idempotent & Declarative
- Rerun-safe: you can apply the playbooks multiple times; they converge to the desired state. This is crucial for recoverability in air-gapped sites.
#### 2. Inventory-Driven
- All topology and host-specific details live in a single inventory. Scaling up or down is a change to data, not to code.
#### 3. Modular, Opinionated-but-Flexible
- Choose container runtime (containerd), CNI (Calico/Cilium/…), add-ons, OS families, etc. Toggle features with variables rather than hand-editing system files.
#### 4. Offline-Friendly
- The contrib/offline toolkit produces authoritative lists of binaries and images for a given version set. That feeds directly into your mirroring pipeline.
#### 5. Security & Compliance
- You control the full supply chain: exact versions, checksums, filesystem presence, and which endpoints are contacted (or not). SELinux/sysctls/firewall are managed consistently.
#### 6. Day-2 Operations
- Built-in playbooks for scale up/down, upgrades, and reset, minimizing custom scripting. You can roll nodes and upgrade in a controlled, repeatable way.
#### 7. Community & Transparency
- It’s open, well-reviewed, and maps closely to upstream Kubernetes primitives, so you’re not locked into a proprietary lifecycle tool.

***Compared to raw kubeadm:*** Kubespray wraps the best practices of kubeadm into reusable, testable roles, plus it covers the system-level details (packages, sysctls, SELinux, service units, container runtime config, image pre-pulls) that are easy to miss in handcrafted scripts—especially offline.

### What this document gives you
- A complete blueprint for your exact topology and IPs, including the Nexus layout you use `/kubespray/{docker.io,ghcr.io,quay.io,registry.k8s.io}`.
- A locked set of versions (Kubernetes, containerd/runc, CNI, etcd, Helm, Calico) and the offline directory structure Kubespray expects.
- Explicit containerd configuration to use HTTP mirrors and, if needed, Basic Auth, with examples of the rendered `hosts.toml` files.
- Minimal add-ons (CoreDNS + Calico) and instructions to disable nginx-proxy and DNS autoscaler for a lean control plane.
- Troubleshooting drawn from real errors (HTTPS vs HTTP pulls, duplicate “v” in versions, archive vs file copy, kubeadm template validation, Calico CRDs), with concrete fixes you can apply immediately.
- Verification and Day-2 guidance (node lifecycle, etcd backups, image checks, DNS sanity tests).


### Scope, assumptions, and success criteria

#### In scope
- Single-control-plane cluster (master1) with etcd collocated.
- Two worker nodes.
- Air-gapped build using Nexus (YUM + Docker hosted).
- `containerd` runtime with pull-through mirrors configured for HTTP on `192.168.154.133:5000`.
- Calico networking (KDD), CoreDNS, kube-proxy; no nginx-proxy, no dns-autoscaler, no metrics-server, no Helm.

#### Assumptions
- All nodes run Rocky 9; SELinux disabled (Kubespray manages policies).
- Time is synchronized; swap is disabled/masked.
- Passwordless SSH from the Kubespray VM to all cluster nodes.
- Adequate firewall allowances inside the cluster; external ingress/egress is not covered here.

#### Success looks like
- `kubectl get nodes` shows master1/worker1/worker2 Ready.
- Only core Pods are running in `kube-system` (apiserver, scheduler, controller-manager, etcd, kube-proxy, CoreDNS, Calico).
- `nerdctl -n k8s.io pull 192.168.154.133:5000/kubespray/registry.k8s.io/kube-apiserver:v1.33.3` succeeds from any node (HTTP mirror working).
- No contacts to the public Internet; all pulls resolve via Nexus.

### Risks, trade-offs, and how this guide mitigates them

- ***HTTP registries*** are insecure on untrusted networks.
Mitigation: use them only on an isolated, trusted LAN. Optionally enable Basic Auth in Nexus and configure `containerd` auths.

- ***Version drift*** causes broken pulls or mismatched binaries/images.
Mitigation: this document pins versions everywhere and embeds the exact `files.list`/`images.list`. Don’t mix versions unless you regenerate artifacts.

- ***Checksum integrity*** can be lost when moving archives.
Mitigation: keep checksums in `offline.yml` for critical binaries (e.g., `runc`, `crictl`); verify after transfer.

- ***Firewall/Sysctl*** surprises can block overlays or kubelet health.
Mitigation: Kubespray enforces the needed modules and sysctls; the document lists the critical ones up front.

### How to read and use this document
- ***1. Read Section 1–2*** to understand the online preparation and why each step exists.
- ***2. Use Section 3–4*** when you stage the offline files and run Kubespray; copy the provided `group_vars`.
- ***3. Keep Section 5–7*** handy during the first converge; it contains the registry mirror/auth details and the exact fixes for common pitfalls.
- ***4. Run the checks in Section 8*** to validate the cluster before handing it to application teams.
- ***5. Refer to Appendices*** for verbatim configs (`offline.yml`, `k8s-cluster.yml`, `containerd.yml`), lists, and helper scripts—so the document is self-contained.

### Quick glossary
- ***Air-gapped:*** No Internet; all artifacts are mirrored inside the LAN.
- ***Nexus (hosted):*** Private repositories you populate yourself (RPMs and Docker).
- ***Kubespray:*** Ansible roles/playbooks for upstream Kubernetes deployments.
- ***containerd:*** Container runtime; pulls images using hosts.toml mirror rules.
- ***CRDs:*** CustomResourceDefinitions; Calico’s KDD manifests are applied as part of networking setup.
- ***Idempotent:*** Safe to re-apply; converges without unintended side effects.

With this foundation, you can move straight into the procedural sections and build the cluster confidently, knowing what is happening, why it’s needed in an air-gapped context, and how to verify each step.

---

## 0) Topology / Addresses / Versions

| Role      | Hostname  | IP              | Notes |
|-----------|-----------|-----------------|-------|
| master    | master1   | 192.168.154.131 | |
| master    | master2   | 192.168.154.132 | |
| master    | master3   | 192.168.154.134 | |
| worker    | worker1   | 192.168.154.135 | |
| worker    | worker2   | 192.168.154.136 | |
| kubespray | kubespray | 192.168.154.137 | Serves offline binaries over HTTP: `http://192.168.154.137:8080/` |
| nexus     | nexus     | 192.168.154.133 | YUM + Docker hosted registry on `:5000 :5001 :5002 :5003` |

**Mirrors (namespaces exist on Nexus):**
- docker.io `192.168.154.133:5000`
- registry.k8s.io `192.168.154.133:5001`
- quay.io `192.168.154.133:5002`
- ghcr.io `192.168.154.133:5003`

##### ***CRI:*** containerd (with nerdctl & ctr)
##### ***CNI:*** Cilium (KDD CRDs)
##### ***Kubernetes version:*** 1.32.5
##### ***Kubespray version:*** 2.28.0

---

## 1) OS & Network Prereqs (ALL nodes: master1/worker1/worker2/kubespray/nexus)

1. **Rocky 9 minimal** install, static IPs as above; correct DNS resolvers.
2. **Time sync:** enable `chronyd` or `systemd-timesyncd`.
3. **Firewall:** allow intra-cluster traffic or temporarily disable it during bootstrap. This typically requires the cluster nodes and their CIDR IP ranges.

   ```bash
   # Accept only cluster nodes
   firewall-cmd --zone=trusted --add-source=192.168.154.131 --permanent
   firewall-cmd --zone=trusted --add-source=192.168.154.132 --permanent
   firewall-cmd --zone=trusted --add-source=192.168.154.134 --permanent
   firewall-cmd --zone=trusted --add-source=192.168.154.135 --permanent
   firewall-cmd --zone=trusted --add-source=192.168.154.136 --permanent

   # Accept only cluster CIDRs (replace with your values)
   firewall-cmd --zone=trusted --add-source=10.233.64.0/18 --permanent
   firewall-cmd --zone=trusted --add-source=10.233.0.0/18 --permanent

   # Apply
   firewall-cmd --reload

   #Verfy your 
   firewall-cmd --liste-sources --zone=trusted
   ```
   
OR

   ```bash
   systemctl disable firewalld && systemctl stop firewalld
   ```

4. **/etc/hosts** (optional, but helpful): map hostnames ↔ IPs.

   ```bash
   cat <<EOF | sudo tee /etc/hosts
   127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
   ::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
   192.168.154.131 master1
   192.168.154.132 master2
   192.168.154.134 master3
   192.168.154.135 worker1
   192.168.154.136 worker2
   192.168.154.133 nexus
   192.168.154.137 kubespray
   EOF
   ```
9. **Passwordless SSH** from the Kubespray node to all cluster nodes (root or a sudoer).

```bash
# On 192.168.154.137 (kubespray VM)
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
for h in master1 master2 master3 worker1 worker2; do ssh-copy-id root@$h; done
# quick check:
ansible all -i "master1,master2,master3,worker1,worker2," -m ping -u root
```
---

## 2) Online Preparation (do these on an **internet‑connected** Rocky 9 VM)

> This primes everything: **RPMs**, **Kubespray code**, **pip wheels**, **container images**, and **offline binaries**.

### 2.1 Seed RPM repositories (EPEL & Docker CE), sync, and archive
```bash
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
dnf install -y epel-release yum-utils
reposync -p /mnt --download-metadata --newest-only
tar cvzf mnt.tar.gz /mnt
```

**Why:** `mnt/` contains all enabled repos + metadata. You’ll push these into a YUM (hosted) repo on Nexus.

### 2.2 Get the latest Kubespray source from https://github.com/kubernetes-sigs/kubespray
```bash
cd /opt
curl -LO https://github.com/kubernetes-sigs/kubespray/archive/refs/tags/v2.28.0.tar.gz
```

### 2.3 Prepare Python 3.12, virtualenv, Ansible, and wheel cache
```bash
dnf install -y python3.12 python3.12-pip
alternatives --install /usr/bin/python3 python /usr/bin/python3.12 10
alternatives --install /usr/bin/python3 python /usr/bin/python3.9 20

dnf install -y ansible

python3 -m venv /opt/ks-venv
source /opt/ks-venv/bin/activate

pip install --upgrade pip
pip download -r /opt/kubespray/requirements.txt -d /opt/pip-req
pip download twine -d /opt/pip-req
tar cvfz pypi.tar.gz ./pip-req
```

**Why:** You’ll install Kubespray’s Python deps offline using this wheel cache.

### 2.4 Generate offline lists from Kubespray and download everything
```bash
cd /opt/kubespray/contrib/offline
./generate_list.sh             # creates ./tmp/files.list and ./tmp/images.list files
```
<a id="dowloader-scripts-list"></a>
- [`./files.sh`](#download-files)                               # downloads all required binaries per files.list
- [`./images.sh`](#download-images)                             # pulls & saves container images listed in images.list
- [`./images-test.sh`](#download-left-over-images)              # optional validation of saved images and download the leftover images

> `images.sh` requires Docker to be running on the internet-connected VM. Note that the tag currently applied to images by the `images.sh` script is only a temporary identifier. In the future, each image will be pushed to its own private repository, based on the registry it comes from. We will not push all images to a single repository after extracting them. Instead, we will retag them according to the registry prefix. For example, images that start with `docker.io` or `ghcr.io` will receive different tags (as described earlier), mapped to the appropriate Nexus port for each registry. This way, each image is pushed to its corresponding private repository.

### 2.5 Seed **Nexus** with YUM + Docker hosted registries (in the offline LAN)

1) **Push RPMs**  
   - Copy `mnt.tar.gz` to Nexus and extract:
     
     ```bash
     tar xvzf mnt.tar.gz -C /opt
     ```
   - Use your helper to push packages + repodata into a YUM (hosted) repo (depth=1):
     [./files-push-repo.sh](#files-push-repo)
     <a id="back-to-files-push-repo"></a>
   - Distribute a `local.repo` to **all offline hosts** under `/etc/yum.repos.d/` pointing to the Nexus YUM baseurl(s):  
     ```ini
      [docker-from-nexus]
      name=Docker CE (from Nexus)
      baseurl=http://192.168.154.133:8081/repository/local/Docker-Ce-Stable
      enabled=1
      gpgcheck=0
      repo_gpgcheck=0
      module_hotfixes=1
      
      [appstream]
      name=appstream (from Nexus)
      baseurl=http://192.168.154.133:8081/repository/local/AppStream/
      enabled=1
      gpgcheck=0
      repo_gpgcheck=0
      module_hotfixes=1
      
      [baseos]
      name=baseos (from Nexus)
      baseurl=http://192.168.154.133:8081/repository/local/BaseOS/
      enabled=1
      gpgcheck=0
      repo_gpgcheck=0
      module_hotfixes=1
      
      [epel]
      name=epel (from Nexus)
      baseurl=http://192.168.154.133:8081/repository/local/EPEL/
      enabled=1
      gpgcheck=0
      repo_gpgcheck=0
      module_hotfixes=1
      
      [extras]
      name=extras (from Nexus)
      baseurl=http://192.168.154.133:8081/repository/local/Extras/
      enabled=1
      gpgcheck=0
      repo_gpgcheck=0
      module_hotfixes=1
      
      [epel-cisco-openh264]
      name=epel-cisco-openh264 (from Nexus)
      baseurl=http://192.168.154.133:8081/repository/local/Epel-Cisco-Openh264/
      enabled=1
      gpgcheck=0
      repo_gpgcheck=0
      module_hotfixes=1

     ```
   - Refresh + update on your **all offline hosts**:
     ```bash
     dnf clean all && dnf makecache
     dnf update -y && dnf upgrade -y
     ```

2) **Push container images to Docker (hosted) repositories on Nexus**  
   - Install Docker **on Nexus** and allow HTTP for your hosted registry:
     ```bash
     dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

     # Add to /usr/lib/systemcd/system/docker.service file on ExecStart section(drop-in file):
     #   --insecure-registry=192.168.154.133:5000 --insecure-registry=192.168.154.133:5001 --insecure-registry=192.168.154.133:5002 --insecure-registry=192.168.154.133:5003
     systemctl daemon-reload
     systemctl restart docker

     docker login 192.168.154.133:5000
     docker login 192.168.154.133:5001
     docker login 192.168.154.133:5002
     docker login 192.168.154.133:5003
     ```
     <a id="load-retag-push"></a>
   - Load & retag & push:
     [./images-load-and-retag.sh](sh-images-load-and-retag)
     
   This script re-tags images under `192.168.154.133:5000/kubespray/<upstream>/<image>:<tag>` and pushes them.

---

## 3) Kubespray Host (offline) — Stage binaries and serve via HTTP

1) Place the offline-files.tar.gz at `/srv`:
```
cd /srv
tar xvzf offline-files.tar.gz

/srv/offline-files/
  dl.k8s.io/release/v1.33.3/bin/linux/amd64/{kubeadm,kubelet,kubectl}
  get.helm.sh/helm-v3.18.4-linux-amd64.tar.gz
  github.com/containerd/containerd/releases/download/v2.1.3/containerd-2.1.3-linux-amd64.tar.gz
  github.com/opencontainers/runc/releases/download/v1.3.0/runc.amd64
  github.com/kubernetes-sigs/cri-tools/releases/download/v1.33.0/crictl-v1.33.0-linux-amd64.tar.gz
  github.com/containernetworking/plugins/releases/download/v1.4.1/cni-plugins-linux-amd64-v1.4.1.tgz
  github.com/etcd-io/etcd/releases/download/v3.5.21/etcd-v3.5.21-linux-amd64.tar.gz
  github.com/containerd/nerdctl/releases/download/v2.1.2/nerdctl-2.1.2-linux-amd64.tar.gz
  github.com/projectcalico/calico/releases/download/v3.29.4/calicoctl-linux-amd64
  github.com/projectcalico/calico/archive/v3.29.4.tar.gz
```
2.1) Option1 ---> Serve them over HTTP:
```bash
nohup python3.12 -m http.server 8080 --directory /srv/offline-files >/var/log/offline-files-http.log 2>&1 &
echo $! > /var/run/offline-files-http.pid
# files_repo => http://192.168.154.137:8080
```

2.1) Option2 (Recommended) ---> Serve them via an raw (hosted) repository on nexus named **files**:
```bash
cd /srv
tar xvzf offline-files.tar.gz
mkdir raw
cp -r offline-files/* raw

/srv/raw/
  dl.k8s.io/release/v1.33.3/bin/linux/amd64/{kubeadm,kubelet,kubectl}
  get.helm.sh/helm-v3.18.4-linux-amd64.tar.gz
  github.com/containerd/containerd/releases/download/v2.1.3/containerd-2.1.3-linux-amd64.tar.gz
  github.com/opencontainers/runc/releases/download/v1.3.0/runc.amd64
  github.com/kubernetes-sigs/cri-tools/releases/download/v1.33.0/crictl-v1.33.0-linux-amd64.tar.gz
  github.com/containernetworking/plugins/releases/download/v1.4.1/cni-plugins-linux-amd64-v1.4.1.tgz
  github.com/etcd-io/etcd/releases/download/v3.5.21/etcd-v3.5.21-linux-amd64.tar.gz
  github.com/containerd/nerdctl/releases/download/v2.1.2/nerdctl-2.1.2-linux-amd64.tar.gz
  github.com/projectcalico/calico/releases/download/v3.29.4/calicoctl-linux-amd64
  github.com/projectcalico/calico/archive/v3.29.4.tar.gz

FILES=$(find raw -type f)

# Push the files to the repository named raw (replace the repository URL with your own values), which is a **raw (hosted)** repository in Nexus Repository Manager.
for i in $FILES do; curl -v --user 'admin:123' --upload-file $i http://192.168.154.133:8081/repository/${i}; done

# files_repo => http://192.168.154.133:8081/repository/raw

```
---

## 4) Kubespray Inventory / Python / Install

On the Kubespray host:
```bash
cd /opt
tar xvf kubespray.tar.gz

dnf install -y python3.12 python3.12-pip
alternatives --install /usr/bin/python3 python /usr/bin/python3.12 10
alternatives --install /usr/bin/python3 python /usr/bin/python3.9 20
alternatives --config python

#   There are 2 programs which provide 'python'.
#   
#     Selection    Command
#   -----------------------------------------------
#      1           /usr/bin/python3.12
#   *+ 2           /usr/bin/python3.9
#
#   Enter to keep the current selection[+], or type selection number: 1

dnf install -y ansible
python -m venv /opt/ks-venv
source /opt/ks-venv/bin/activate
python3.12 -m pip install --no-index --find-links /opt/pip-req -r /opt/kubespray/requirements.txt

# Build the proper inventory using Kubespray's built-in inventory builder.
cd /opt/kubespray/inventory
cp -r sample ./mycluster
cd mycluster
cat <<EOF | sudo tee inventory.ini
master1 ansible_host=192.168.154.131 ansible_port=22 ip=192.168.154.131 etcd_member_name=etcd1
master2 ansible_host=192.168.154.132 ansible_port=22 ip=192.168.154.132 etcd_member_name=etcd2
master3 ansible_host=192.168.154.134 ansible_port=22 ip=192.168.154.134 etcd_member_name=etcd3
worker1 ansible_host=192.168.154.135 ansible_port=22 ip=192.168.154.135
worker2 ansible_host=192.168.154.136 ansible_port=22 ip=192.168.154.136
[kube_control_plane]
master1
master2
master3

[etcd:children]
kube_control_plane

[kube_node]
worker1
worker2

EOF
```
#### Notes

- `master1`, `master2`, … are **hostnames** (Ansible inventory names).
- `ansible_host` = the **SSH target address** Ansible uses to connect.
- `ansible_port=22` = SSH port (22 is default; you can omit it if you use 22).
- `ip` = the node’s **internal/node IP** that Kubernetes should use (node IP / advertise IP). This can equal ansible_host, but often differs in multi-NIC setups.
- `etcd_member_name` = the **name of the etcd** peer for that master (used when forming the etcd cluster).

- With Kubespray, the inventory builder will make only the first IP a control-plane + etcd node by default and put the rest as workers. If you want multiple masters, you just edit the generated inventory to add those hosts to the `kube_control_plane` (and usually `etcd`) groups. So you should open `inventory/mycluster/hosts.yaml` and put the extra masters under the `kube_control_plane` (and, typically, `etcd`) groups.
- etcd size should be odd (1, 3, 5…). For HA, use 3 etcd members—often colocated on the 3 masters.
- Masters are tainted by default (unschedulable); if you want them to run workloads, remove taints later.
- For multi-master you need a stable API endpoint. Either provide an external load balancer (VIP/DNS) to front the masters, or enable a built-in option (e.g., kube-vip/HAProxy depending on your Kubespray version) in group vars. Set the control-plane endpoint to that VIP/DNS before deploying.


<a id="gv-list"></a>
Copy your prepared **group_vars** into place:

- [inventory/mycluster/group_vars/offline.yml](#gv-offline)
- [inventory/mycluster/group_vars/k8s-cluster.yml](#gv-k8s)
- [inventory/mycluster/group_vars/containerd.yml](#gv-containerd)

#### Log visibility in Kubespray (`no_log` & `unsafe_show_logs`)
- `no_log` (Ansible): hides module args/results in output/logs. Ansible default is false, but Kubespray often sets `no_log: "{{ not (unsafe_show_logs | bool) }}"`, so the effective default is hidden.
- `unsafe_show_logs` (Kubespray): global switch (default false). Set to true to flip most Kubespray tasks to show full output (useful for deep debugging).
- How to enable (temporarily): per cluster in `inventory/mycluster/group_vars/all/all.yml` → `unsafe_show_logs: true`, or per run: `ansible-playbook … -e unsafe_show_logs=true -vvv`
- Security note: enabling exposes secrets (`tokens/passwords/certs`). Use briefly, then set back to `false` and scrub any captured logs.



Run the deployment:
```bash
ansible-playbook -i inventory/mycluster/hosts.yaml -b cluster.yml -vv
```

If everything completes successfully, the output should look like the following—no failures.
```
Saturday 16 August 2025  22:24:24 -0400 (0:00:00.044)       0:05:20.961 *******
Saturday 16 August 2025  22:24:24 -0400 (0:00:00.043)       0:05:21.005 *******
Saturday 16 August 2025  22:24:24 -0400 (0:00:00.040)       0:05:21.046 *******
Saturday 16 August 2025  22:24:24 -0400 (0:00:00.037)       0:05:21.083 *******
Saturday 16 August 2025  22:24:24 -0400 (0:00:00.035)       0:05:21.119 *******

PLAY RECAP *****************************************************************************************************************************************************************************************************************************
master1                    : ok=510  changed=48   unreachable=0    failed=0    skipped=882  rescued=0    ignored=1
worker1                    : ok=323  changed=24   unreachable=0    failed=0    skipped=533  rescued=0    ignored=1
worker2                    : ok=323  changed=24   unreachable=0    failed=0    skipped=533  rescued=0    ignored=1

Saturday 16 August 2025  22:24:24 -0400 (0:00:00.102)       0:05:21.222 *******
===============================================================================
container-engine/containerd : Containerd | Unpack containerd archive ------------------------------------------------------------------------------------------------------------------------------------------------------------ 7.83s
/opt/kubespray/roles/container-engine/containerd/tasks/main.yml:7 ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
system_packages : Manage packages ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- 7.38s
/opt/kubespray/roles/system_packages/tasks/main.yml:37 --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
kubernetes-apps/ansible : Kubernetes Apps | CoreDNS ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- 5.01s
/opt/kubespray/roles/kubernetes-apps/ansible/tasks/main.yml:14 ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
container-engine/containerd : Containerd | Write hosts.toml file ---------------------------------------------------------------------------------------------------------------------------------------------------------------- 4.11s
/opt/kubespray/roles/container-engine/containerd/tasks/main.yml:85 --------------------------------------------------------------------------------------------------------------------------------------------------------------------
container-engine/validate-container-engine : Populate service facts ------------------------------------------------------------------------------------------------------------------------------------------------------------- 4.10s
/opt/kubespray/roles/container-engine/validate-container-engine/tasks/main.yml:25 -----------------------------------------------------------------------------------------------------------------------------------------------------
kubernetes/node : Install | Copy kubelet binary from download dir --------------------------------------------------------------------------------------------------------------------------------------------------------------- 4.06s
/opt/kubespray/roles/kubernetes/node/tasks/install.yml:13 -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
network_plugin/calico : Calico | Create calico manifests ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ 3.68s
/opt/kubespray/roles/network_plugin/calico/tasks/install.yml:382 ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
download : Download_file | Download item ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- 3.19s
/opt/kubespray/roles/download/tasks/download_file.yml:59 ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
container-engine/crictl : Extract_file | Unpacking archive ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- 3.06s
/opt/kubespray/roles/download/tasks/extract_file.yml:2 --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

```

---

## 5) Containerd & Registry Mirrors (HTTP + optional Basic Auth)

We use Kubespray variables to generate containerd configs and **hosts.toml** per registry:

- Map upstream registries → your Nexus mirrors.
- Allow **plain HTTP** to `192.168.154.133:5000` (`containerd_insecure_registries`).
- Provide Basic auth (`containerd_registry_auth`/`auths`) if your Nexus hosted requires login.
- Optionally inject headers or custom `hosts.toml` via `containerd_custom_hosts_conf` (rarely needed when auths are provided).

**Quick validation after a run:**
```bash
systemctl status containerd
ls -1 /etc/containerd/certs.d/
cat /etc/containerd/certs.d/registry.k8s.io/hosts.toml
nerdctl -n k8s.io pull 192.168.154.133:5000/kubespray/registry.k8s.io/kube-apiserver:v1.33.3
ctr -n k8s.io images ls | grep kube-apiserver
```

If you see `server ... does not seem to support HTTPS`, a host file is pointing to `https://` or your insecure registry list is missing the Nexus host:port. Ensure `server = "http://..."` and `skip_verify = true` in the generated `hosts.toml` files and that `192.168.154.133:5000` appears under `containerd_insecure_registries`.

---

## 6) Minimal Add‑ons Only (no nginx‑proxy, no dns‑autoscaler, etc.)

We keep only **kube‑apiserver, kube‑scheduler, kube‑controller‑manager, etcd, kube‑proxy, coredns, calico‑node/controllers**.

In `k8s-cluster.yml`:
```yaml
nginx_proxy_enable: false
dns_autoscaler_enabled: false
metrics_server_enabled: false
helm_enabled: false
```

If previously deployed, remove:
```bash
kubectl -n kube-system delete ds -l k8s-app=nginx-proxy --ignore-not-found
kubectl -n kube-system delete deploy -l k8s-app=dns-autoscaler --ignore-not-found
```

---

## 7) Troubleshooting Cheatsheet (from real errors I fixed)

- **HTTPS attempted against HTTP registry**
  - Symptom: `server ... does not seem to support HTTPS`
  - Fix: ensure `server="http://192.168.154.133:5000/..."` in `/etc/containerd/certs.d/*/hosts.toml` and set `containerd_insecure_registries: ['192.168.154.133:5000']`

- **`download.dest` / `download_cache_dir` undefined**
  - Cause: malformed/duplicate `downloads:` blocks or missing keys.
  - Fix: have a single `downloads:` map; each item needs `url`, `dest`, `mode`, optional `checksum`; add `unarchive: true` for tarballs.

- **`crictl` not found**
  - Ensure the archive is unpacked so that `/tmp/releases/crictl` exists before copying to `/usr/local/bin/crictl` (we set `unarchive: true`).

- **etcd path like `etcd-vv3.5.21`**
  - Remove the extra `v` in version variables; keep filenames as released (`v3.5.21`) and avoid templating `v` twice.

- **kubeadm template validation error**
  - If you see `host '' must be a valid IP...`, unset any unused LB domain and set `kube_apiserver_bind_address` (or keep Kubespray defaults).

- **Calico KDD CRDs missing**
  - Ensure `calico_crds_download_url` points at the Calico tarball and the role extracts to a path Kubespray expects (we provide mapping in offline.yml).

- **Images fail to pull during bootstrap**
  - Test first with nerdctl: `nerdctl -n k8s.io pull <your-mirror>/<image>:<tag>`.

---

## 8) Post‑Install Verification

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl -n kube-system get ds,deploy | awk 'NR==1 || /calico|coredns|kube-/'
# Container runtime
crictl info | head
ctr -n k8s.io images ls | head
# DNS sanity
kubectl -n kube-system get svc kube-dns
kubectl run -it --rm --image=busybox:1.36 --restart=Never dns-test -- nslookup kubernetes.default
```

Expected pods (steady state): apiserver/scheduler/controller-manager on master1; etcd on master1; coredns (2 replicas by default); calico-node on each node; kube-proxy on each node; calico-kube-controllers.

---

## 9) Day‑2 Notes (brief)

- **Add a worker:** put it in inventory, ensure OS prereqs + repo access, then `--limit <newnode> -b scale.yml`.
- **Remove a node:** `remove-node.yml` (cordon/drain first).
- **Back up etcd:** `ETCDCTL_API=3 etcdctl snapshot save /var/backups/etcd-$(date +%F).db` (run on etcd node).
- **Upgrades:** require pre-staging new images and binaries offline; follow Kubespray’s version constraints meticulously.

---

## 10) Appendices (effective configurations)

<a id="gv-offline"></a>
[↩ back to YMLs list](#gv-list)
### A) `inventory/mycluster/group_vars/offline.yml`
```yaml
---
# === Offline root if served by your mini HTTP server ===> files_repo: "http://192.168.154.137:8080"

# === Offline root served by your raw (hosted) repository ===

files_repo: "http://192.168.154.133:8081/repository/files"

# === Common ===
image_arch: "amd64"
kube_version: "1.33.3"       # no leading v (Kubespray compares this)
local_release_dir: "/tmp/releases"
download_cache_dir: "/tmp/kubespray_cache"
download_run_once: false

# who to delegate run_once downloads to (safe default)
download_delegate: "{{ groups['kube_control_plane'][0] | default(inventory_hostname) }}"

# Default for any download that doesn't override (crucial: groups!)
download_defaults:
  enabled: true
  groups:
    - kube_control_plane
    - kube_node

# === Versions (exactly what you mirrored) ===
containerd_version: "2.1.3"
nerdctl_version: "2.1.2"
runc_version: "1.3.0"
crictl_version: "v1.33.0"    # keep the 'v' – your tarball has it
cni_version: "v1.4.1"        # includes 'v' in file name
etcd_version: "3.5.21"       # no 'v' for comparisons
helm_version: "v3.18.4"      # includes 'v' in file name
calico_version: "3.29.4"     # no 'v' for comparisons

# === Filenames we’ll reference in dest paths ===
runc_binary: "runc.{{ image_arch }}"
crictl_filename: "crictl-{{ crictl_version }}-linux-{{ image_arch }}.tar.gz"
containerd_filename: "containerd-{{ containerd_version }}-linux-{{ image_arch }}.tar.gz"
nerdctl_filename: "nerdctl-{{ nerdctl_version }}-linux-{{ image_arch }}.tar.gz"
cni_filename: "cni-plugins-linux-{{ image_arch }}-{{ cni_version }}.tgz"
etcd_filename: "etcd-v{{ etcd_version }}-linux-{{ image_arch }}.tar.gz"
helm_filename: "helm-{{ helm_version }}-linux-{{ image_arch }}.tar.gz"
calicoctl_binary: "calicoctl-linux-{{ image_arch }}"
calico_crds_filename: "v{{ calico_version }}.tar.gz"

# === URLs that match your /srv/offline-files tree ===
kubeadm_download_url:  "{{ files_repo }}/dl.k8s.io/release/v{{ kube_version }}/bin/linux/{{ image_arch }}/kubeadm"
kubelet_download_url:  "{{ files_repo }}/dl.k8s.io/release/v{{ kube_version }}/bin/linux/{{ image_arch }}/kubelet"
kubectl_download_url:  "{{ files_repo }}/dl.k8s.io/release/v{{ kube_version }}/bin/linux/{{ image_arch }}/kubectl"

containerd_download_url:  "{{ files_repo }}/github.com/containerd/containerd/releases/download/v{{ containerd_version }}/{{ containerd_filename }}"
nerdctl_download_url:     "{{ files_repo }}/github.com/containerd/nerdctl/releases/download/v{{ nerdctl_version }}/{{ nerdctl_filename }}"
runc_download_url:        "{{ files_repo }}/github.com/opencontainers/runc/releases/download/v{{ runc_version }}/{{ runc_binary }}"
crictl_download_url:      "{{ files_repo }}/github.com/kubernetes-sigs/cri-tools/releases/download/{{ crictl_version }}/{{ crictl_filename }}"
cni_download_url:         "{{ files_repo }}/github.com/containernetworking/plugins/releases/download/{{ cni_version }}/{{ cni_filename }}"
etcd_download_url:        "{{ files_repo }}/github.com/etcd-io/etcd/releases/download/v{{ etcd_version }}/{{ etcd_filename }}"
helm_download_url:        "{{ files_repo }}/get.helm.sh/{{ helm_filename }}"
calicoctl_download_url:   "{{ files_repo }}/github.com/projectcalico/calico/releases/download/v{{ calico_version }}/{{ calicoctl_binary }}"
calico_crds_download_url: "{{ files_repo }}/github.com/projectcalico/calico/archive/{{ calico_crds_filename }}"

# === Checksums (fill the placeholders; keep the sha256: prefix) ===

# compute these and paste (see quick commands below)
kubeadm_checksum:  "sha256:baaa1f7621c9c239cd4ac3be5b7e427df329d7e1e15430db5f6ea5bb7a15a02b"
kubelet_checksum:  "sha256:37f9093ed2b4669cccf5474718e43ec412833e1267c84b01e662df2c4e5d7aaa"
kubectl_checksum:  "sha256:2fcf65c64f352742dc253a25a7c95617c2aba79843d1b74e585c69fe4884afb0"

containerd_checksum:  "sha256:436cc160c33b37ec25b89fb5c72fc879ab2b3416df5d7af240c3e9c2f4065d3c"
nerdctl_checksum:     "sha256:1a08c35d16a0db0b4ac298adb8e4dab4293803d492cbba7aaf862a48a04c463d"
runc_checksum:        "sha256:028986516ab5646370edce981df2d8e8a8d12188deaf837142a02097000ae2f2"
crictl_checksum:      "sha256:8307399e714626e69d1213a4cd18c8dec3d0201ecdac009b1802115df8973f0f"
cni_checksum:         "sha256:2a0ea7072d1806b8526489bcd3b4847a06ab010ee32ba3c3d4e5a3235d3eb138"
etcd_checksum:        "sha256:adddda4b06718e68671ffabff2f8cee48488ba61ad82900e639d108f2148501c"
helm_checksum:        "sha256:f8180838c23d7c7d797b208861fecb591d9ce1690d8704ed1e4cb8e2add966c1"
calicoctl_checksum:   "sha256:f2a6da6e97052da3b8b787aaea61fa83298586e822af8b9ec5f3858859de759c"
calico_crds_checksum: "sha256:6d2396fde36ba59ad55a92b5b66643adcc9ee13bb2b3986b1014e2f8f95fa861"

# === Single consolidated downloads map (covers all roles/tags) ===
downloads:
  kubeadm:
    enabled:  true
    groups:   [kube_control_plane, kube_node]
    container: false
    url:      "{{ kubeadm_download_url }}"
    dest:     "{{ local_release_dir }}/kubeadm-{{ kube_version }}-{{ image_arch }}"
    mode:     "0755"
    checksum: "{{ kubeadm_checksum }}"
  kubelet:
    enabled:  true
    groups:   [kube_control_plane, kube_node]
    container: false
    url:      "{{ kubelet_download_url }}"
    dest:     "{{ local_release_dir }}/kubelet-{{ kube_version }}-{{ image_arch }}"
    mode:     "0755"
    checksum: "{{ kubelet_checksum }}"
  kubectl:
    enabled:  true
    groups:   [kube_control_plane, kube_node]
    container: false
    url:      "{{ kubectl_download_url }}"
    dest:     "{{ local_release_dir }}/kubectl-{{ kube_version }}-{{ image_arch }}"
    mode:     "0755"
    checksum: "{{ kubectl_checksum }}"

  containerd:
    enabled:  true
    groups:   [kube_control_plane, kube_node]
    container: false
    url:      "{{ containerd_download_url }}"
    dest:     "{{ local_release_dir }}/{{ containerd_filename }}"
    mode:     "0644"
    checksum: "{{ containerd_checksum }}"
    # leave unarchive to the containerd role

  nerdctl:
    enabled:  true
    groups:   [kube_control_plane, kube_node]
    container: false
    url:      "{{ nerdctl_download_url }}"
    dest:     "{{ local_release_dir }}/{{ nerdctl_filename }}"
    mode:     "0644"
    checksum: "{{ nerdctl_checksum }}"
    unarchive: true
    # the nerdctl role unpacks it via its own Extract_file task

  runc:
    enabled:  true
    groups:   [kube_control_plane, kube_node]
    container: false
    url:      "{{ runc_download_url }}"
    dest:     "{{ local_release_dir }}/{{ runc_binary }}"
    mode:     "0755"
    checksum: "{{ runc_checksum }}"

  crictl:
    enabled:  true
    groups:   [kube_control_plane, kube_node]
    container: false
    url:      "{{ crictl_download_url }}"
    dest:     "{{ local_release_dir }}/{{ crictl_filename }}"
    mode:     "0644"
    checksum: "{{ crictl_checksum }}"
    unarchive: true   # crictl copy step expects /tmp/releases/crictl

  cni:
    enabled:  true
    groups:   [kube_control_plane, kube_node]
    container: false
    url:      "{{ cni_download_url }}"
    dest:     "{{ local_release_dir }}/{{ cni_filename }}"
    mode:     "0644"
    checksum: "{{ cni_checksum }}"
    # CNI role handles extraction

  etcd:
    enabled:  true
    groups:   [etcd, kube_control_plane]
    container: false
    url:      "{{ etcd_download_url }}"
    dest:     "{{ local_release_dir }}/{{ etcd_filename }}"
    mode:     "0644"
    checksum: "{{ etcd_checksum }}"
    unarchive: true
    # etcdctl/etcdutl roles extract from this tarball

  helm:
    enabled:  true
    groups:   [kube_control_plane]
    container: false
    url:      "{{ helm_download_url }}"
    dest:     "{{ local_release_dir }}/{{ helm_filename }}"
    mode:     "0644"
    checksum: "{{ helm_checksum }}"
    # Helm role handles extraction

  calicoctl:
    enabled:  true
    groups:   [kube_control_plane, kube_node]
    container: false
    url:      "{{ calicoctl_download_url }}"
    dest:     "{{ local_release_dir }}/{{ calicoctl_binary }}"
    mode:     "0755"
    checksum: "{{ calicoctl_checksum }}"

  calico_crds:
    enabled:  true
    groups:   [kube_control_plane, kube_node]
    container: false
    url:      "{{ calico_crds_download_url }}"
    dest:     "{{ local_release_dir }}/{{ calico_crds_filename }}"
    mode:     "0644"
    checksum: "{{ calico_crds_checksum }}"

# --- Also provide the alternate shapes some Kubespray tags read ---
kubeadm_download:     "{{ downloads.kubeadm }}"
kubelet_download:     "{{ downloads.kubelet }}"
kubectl_download:     "{{ downloads.kubectl }}"
containerd_download:  "{{ downloads.containerd }}"
nerdctl_download:     "{{ downloads.nerdctl }}"
runc_download:        "{{ downloads.runc }}"
crictl_download:      "{{ downloads.crictl }}"
cni_download:         "{{ downloads.cni }}"
etcd_download:        "{{ downloads.etcd }}"
helm_download:        "{{ downloads.helm }}"
calicoctl_download:   "{{ downloads.calicoctl }}"
calico_crds_download: "{{ downloads.calico_crds }}"

# --- Image registries (your Nexus mirrors) ---

registry_host: "192.168.154.133:5000"
kube_image_repo:   "192.168.154.133:5000/kubespray/registry.k8s.io"
gcr_image_repo:    "192.168.154.133:5000/kubespray/registry.k8s.io"
docker_image_repo: "192.168.154.133:5000/kubespray/docker.io"
quay_image_repo:   "192.168.154.133:5000/kubespray/quay.io"
github_image_repo: "192.168.154.133:5000/kubespray/ghcr.io"

  #containerd_registries_mirrors:
  #  - prefix: "docker.io"
  #    mirrors:
  #      - host: "http://192.168.154.133:500/kubespray"
  #        capabilities: ["pull", "resolve"]
  #    override_path: true
  #    skip_verify: true
  #
  #  - prefix: "quay.io"
  #    mirrors:
  #      - host: "http://192.168.154.133:5000/kubespray"
  #        capabilities: ["pull", "resolve"]
  #    override_path: true
  #    skip_verify: true
  #
  #  - prefix: "ghcr.io"
  #    mirrors:
  #      - host: "http://192.168.154.133:5000/kubespray"
  #        capabilities: ["pull", "resolve"]
  #    override_path: true
  #    skip_verify: true
  #
  #  - prefix: "registry.k8s.io"
  #    mirrors:
  #      - host: "http://192.168.154.133:5000/kubespray"
  #        capabilities: ["pull", "resolve"]
  #    override_path: true
  #    skip_verify: true
  #
  #containerd_registry_auth:
  #  - registry: "192.168.154.133:5000"
  #    username: "admin"
  #    password: "123"


  # # Treat Nexus (port 5000) as plain HTTP
  # containerd_insecure_registries:
  #   - "192.168.154.133:5000"
  # 
  # # (Optional but recommended) registry mirrors for upstream names
  # containerd_registry_mirrors:
  #   "registry.k8s.io":
  #     - "http://192.168.154.133:5000/kubespray/registry.k8s.io"
  #   "k8s.gcr.io":
  #     - "http://192.168.154.133:5000/kubespray/registry.k8s.io"
  #   "docker.io":
  #     - "http://192.168.154.133:5000/kubespray/docker.io"
  #   "quay.io":
  #     - "http://192.168.154.133:5000/kubespray/quay.io"
  #   "ghcr.io":
  #     - "http://192.168.154.133:5000/kubespray/ghcr.io"
  # 

```
[↩ back to YMLs list](#gv-list)
<a id="gv-k8s"></a>
### B) `inventory/mycluster/group_vars/k8s-cluster.yml`
```yaml
---
# Kubernetes configuration dirs and system namespace.
# Those are where all the additional config stuff goes
# the kubernetes normally puts in /srv/kubernetes.
# This puts them in a sane location and namespace.
# Editing those values will almost surely break something.
kube_config_dir: /etc/kubernetes
kube_script_dir: "{{ bin_dir }}/kubernetes-scripts"
kube_manifest_dir: "{{ kube_config_dir }}/manifests"

# This is where all the cert scripts and certs will be located
kube_cert_dir: "{{ kube_config_dir }}/ssl"

# This is where all of the bearer tokens will be stored
kube_token_dir: "{{ kube_config_dir }}/tokens"

kube_api_anonymous_auth: true

# Where the binaries will be downloaded.
# Note: ensure that you've enough disk space (about 1G)
local_release_dir: "/tmp/releases"
# Random shifts for retrying failed ops like pushing/downloading
retry_stagger: 5

# This is the user that owns tha cluster installation.
kube_owner: kube

# This is the group that the cert creation scripts chgrp the
# cert files to. Not really changeable...
kube_cert_group: kube-cert

# Cluster Loglevel configuration
kube_log_level: 2

# Directory where credentials will be stored
credentials_dir: "{{ inventory_dir }}/credentials"

## It is possible to activate / deactivate selected authentication methods (oidc, static token auth)
# kube_oidc_auth: false
# kube_token_auth: false


## Variables for OpenID Connect Configuration https://kubernetes.io/docs/admin/authentication/
## To use OpenID you have to deploy additional an OpenID Provider (e.g Dex, Keycloak, ...)

# kube_oidc_url: https:// ...
# kube_oidc_client_id: kubernetes
## Optional settings for OIDC
# kube_oidc_ca_file: "{{ kube_cert_dir }}/ca.pem"
# kube_oidc_username_claim: sub
# kube_oidc_username_prefix: 'oidc:'
# kube_oidc_groups_claim: groups
# kube_oidc_groups_prefix: 'oidc:'

## Variables to control webhook authn/authz
# kube_webhook_token_auth: false
# kube_webhook_token_auth_url: https://...
# kube_webhook_token_auth_url_skip_tls_verify: false

## For webhook authorization, authorization_modes must include Webhook or kube_apiserver_authorization_config_authorizers must configure a type: Webhook
# kube_webhook_authorization: false
# kube_webhook_authorization_url: https://...
# kube_webhook_authorization_url_skip_tls_verify: false

# Choose network plugin (cilium, calico, kube-ovn or flannel. Use cni for generic cni plugin)
# Can also be set to 'cloud', which lets the cloud provider setup appropriate routing
kube_network_plugin: calico

# Setting multi_networking to true will install Multus: https://github.com/k8snetworkplumbingwg/multus-cni
kube_network_plugin_multus: false

# Kubernetes internal network for services, unused block of space.
kube_service_addresses: 10.233.0.0/18

# internal network. When used, it will assign IP
# addresses from this range to individual pods.
# This network must be unused in your network infrastructure!
kube_pods_subnet: 10.233.64.0/18

# internal network node size allocation (optional). This is the size allocated
# to each node for pod IP address allocation. Note that the number of pods per node is
# also limited by the kubelet_max_pods variable which defaults to 110.
#
# Example:
# Up to 64 nodes and up to 254 or kubelet_max_pods (the lowest of the two) pods per node:
#  - kube_pods_subnet: 10.233.64.0/18
#  - kube_network_node_prefix: 24
#  - kubelet_max_pods: 110
#
# Example:
# Up to 128 nodes and up to 126 or kubelet_max_pods (the lowest of the two) pods per node:
#  - kube_pods_subnet: 10.233.64.0/18
#  - kube_network_node_prefix: 25
#  - kubelet_max_pods: 110
kube_network_node_prefix: 24

kube_version: "1.33.3"

# Kubernetes internal network for IPv6 services, unused block of space.
# This is only used if ipv6_stack is set to true
# This provides 4096 IPv6 IPs
kube_service_addresses_ipv6: fd85:ee78:d8a6:8607::1000/116

# Internal network. When used, it will assign IPv6 addresses from this range to individual pods.
# This network must not already be in your network infrastructure!
# This is only used if ipv6_stack is set to true.
# This provides room for 256 nodes with 254 pods per node.
kube_pods_subnet_ipv6: fd85:ee78:d8a6:8607::1:0000/112

# IPv6 subnet size allocated to each for pods.
# This is only used if ipv6_stack is set to true
# This provides room for 254 pods per node.
kube_network_node_prefix_ipv6: 120

# The port the API Server will be listening on.
kube_apiserver_ip: "{{ kube_service_subnets.split(',') | first | ansible.utils.ipaddr('net') | ansible.utils.ipaddr(1) | ansible.utils.ipaddr('address') }}"
kube_apiserver_port: 6443  # (https)

# Kube-proxy proxyMode configuration.
# Can be ipvs, iptables, nftables
# TODO: it needs to be changed to nftables when the upstream use nftables as default
kube_proxy_mode: ipvs

# configure arp_ignore and arp_announce to avoid answering ARP queries from kube-ipvs0 interface
# must be set to true for MetalLB, kube-vip(ARP enabled) to work
kube_proxy_strict_arp: false

# A string slice of values which specify the addresses to use for NodePorts.
# Values may be valid IP blocks (e.g. 1.2.3.0/24, 1.2.3.4/32).
# The default empty string slice ([]) means to use all local addresses.
# kube_proxy_nodeport_addresses_cidr is retained for legacy config
kube_proxy_nodeport_addresses: >-
  {%- if kube_proxy_nodeport_addresses_cidr is defined -%}
  [{{ kube_proxy_nodeport_addresses_cidr }}]
  {%- else -%}
  []
  {%- endif -%}

# If non-empty, will use this string as identification instead of the actual hostname
# kube_override_hostname: {{ inventory_hostname }}

## Encrypting Secret Data at Rest
kube_encrypt_secret_data: false

dns_autoscaler_enabled: false
dnsautoscaler_enabled: false

nginx_proxy_enabled: false  # turns off the nginx-proxy DaemonSet
apiserver_loadbalancer_localhost: false
loadbalancer_apiserver_localhost: false


# Graceful Node Shutdown (Kubernetes >= 1.21.0), see https://kubernetes.io/blog/2021/04/21/graceful-node-shutdown-beta/
# kubelet_shutdown_grace_period had to be greater than kubelet_shutdown_grace_period_critical_pods to allow
# non-critical podsa to also terminate gracefully
# kubelet_shutdown_grace_period: 60s
# kubelet_shutdown_grace_period_critical_pods: 20s

# DNS configuration.
# Kubernetes cluster name, also will be used as DNS domain
cluster_name: cluster.local
# Subdomains of DNS domain to be resolved via /etc/resolv.conf for hostnet pods
ndots: 2
# dns_timeout: 2
# dns_attempts: 2
# Custom search domains to be added in addition to the default cluster search domains
# searchdomains:
#   - svc.{{ cluster_name }}
#   - default.svc.{{ cluster_name }}
# Remove default cluster search domains (``default.svc.{{ dns_domain }}, svc.{{ dns_domain }}``).
# remove_default_searchdomains: false
# Can be coredns, coredns_dual, manual or none
dns_mode: coredns
# Set manual server if using a custom cluster DNS server
# manual_dns_server: 10.x.x.x
# Enable nodelocal dns cache
enable_nodelocaldns: false
enable_nodelocaldns_secondary: false
nodelocaldns_ip: 169.254.25.10
nodelocaldns_health_port: 9254
nodelocaldns_second_health_port: 9256
nodelocaldns_bind_metrics_host_ip: false
nodelocaldns_secondary_skew_seconds: 5
# nodelocaldns_external_zones:
# - zones:
#   - example.com
#   - example.io:1053
#   nameservers:
#   - 1.1.1.1
#   - 2.2.2.2
#   cache: 5
# - zones:
#   - https://mycompany.local:4453
#   nameservers:
#   - 192.168.0.53
#   cache: 0
# - zones:
#   - mydomain.tld
#   nameservers:
#   - 10.233.0.3
#   cache: 5
#   rewrite:
#   - name website.tld website.namespace.svc.cluster.local
# Enable k8s_external plugin for CoreDNS
enable_coredns_k8s_external: false
coredns_k8s_external_zone: k8s_external.local
# Enable endpoint_pod_names option for kubernetes plugin
enable_coredns_k8s_endpoint_pod_names: false
# Set forward options for upstream DNS servers in coredns (and nodelocaldns) config
# dns_upstream_forward_extra_opts:
#   policy: sequential
# Apply extra options to coredns kubernetes plugin
# coredns_kubernetes_extra_opts:
#   - 'fallthrough example.local'
# Forward extra domains to the coredns kubernetes plugin
# coredns_kubernetes_extra_domains: ''

# Can be docker_dns, host_resolvconf or none
resolvconf_mode: host_resolvconf
# Deploy netchecker app to verify DNS resolve as an HTTP service
deploy_netchecker: false
# Ip address of the kubernetes skydns service
skydns_server: "{{ kube_service_subnets.split(',') | first | ansible.utils.ipaddr('net') | ansible.utils.ipaddr(3) | ansible.utils.ipaddr('address') }}"
skydns_server_secondary: "{{ kube_service_subnets.split(',') | first | ansible.utils.ipaddr('net') | ansible.utils.ipaddr(4) | ansible.utils.ipaddr('address') }}"
dns_domain: "{{ cluster_name }}"

## Container runtime
## docker for docker, crio for cri-o and containerd for containerd.
## Default: containerd
container_manager: containerd

# Additional container runtimes
kata_containers_enabled: false

kubeadm_certificate_key: "{{ lookup('password', credentials_dir + '/kubeadm_certificate_key.creds length=64 chars=hexdigits') | lower }}"

# K8s image pull policy (imagePullPolicy)
k8s_image_pull_policy: IfNotPresent

# audit log for kubernetes
kubernetes_audit: false

# define kubelet config dir for dynamic kubelet
# kubelet_config_dir:
default_kubelet_config_dir: "{{ kube_config_dir }}/dynamic_kubelet_dir"

# Make a copy of kubeconfig on the host that runs Ansible in {{ inventory_dir }}/artifacts
kubeconfig_localhost: false
# Use ansible_host as external api ip when copying over kubeconfig.
# kubeconfig_localhost_ansible_host: false
# Download kubectl onto the host that runs Ansible in {{ bin_dir }}
# kubectl_localhost: false

# A comma separated list of levels of node allocatable enforcement to be enforced by kubelet.
# Acceptable options are 'pods', 'system-reserved', 'kube-reserved' and ''. Default is "".
# kubelet_enforce_node_allocatable: pods

## Set runtime and kubelet cgroups when using systemd as cgroup driver (default)
# kubelet_runtime_cgroups: "/{{ kube_service_cgroups }}/{{ container_manager }}.service"
# kubelet_kubelet_cgroups: "/{{ kube_service_cgroups }}/kubelet.service"

## Set runtime and kubelet cgroups when using cgroupfs as cgroup driver
# kubelet_runtime_cgroups_cgroupfs: "/system.slice/{{ container_manager }}.service"
# kubelet_kubelet_cgroups_cgroupfs: "/system.slice/kubelet.service"

# Whether to run kubelet and container-engine daemons in a dedicated cgroup.
# kube_reserved: false
## Uncomment to override default values
## The following two items need to be set when kube_reserved is true
# kube_reserved_cgroups_for_service_slice: kube.slice
# kube_reserved_cgroups: "/{{ kube_reserved_cgroups_for_service_slice }}"
# kube_memory_reserved: 256Mi
# kube_cpu_reserved: 100m
# kube_ephemeral_storage_reserved: 2Gi
# kube_pid_reserved: "1000"

## Optionally reserve resources for OS system daemons.
# system_reserved: true
## Uncomment to override default values
## The following two items need to be set when system_reserved is true
# system_reserved_cgroups_for_service_slice: system.slice
# system_reserved_cgroups: "/{{ system_reserved_cgroups_for_service_slice }}"
# system_memory_reserved: 512Mi
# system_cpu_reserved: 500m
# system_ephemeral_storage_reserved: 2Gi

## Eviction Thresholds to avoid system OOMs
# https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/#eviction-thresholds
# eviction_hard: {}
# eviction_hard_control_plane: {}

# An alternative flexvolume plugin directory
# kubelet_flexvolumes_plugins_dir: /usr/libexec/kubernetes/kubelet-plugins/volume/exec

## Supplementary addresses that can be added in kubernetes ssl keys.
## That can be useful for example to setup a keepalived virtual IP
# supplementary_addresses_in_ssl_keys: [10.0.0.1, 10.0.0.2, 10.0.0.3]

## Running on top of openstack vms with cinder enabled may lead to unschedulable pods due to NoVolumeZoneConflict restriction in kube-scheduler.
## See https://github.com/kubernetes-sigs/kubespray/issues/2141
## Set this variable to true to get rid of this issue
volume_cross_zone_attachment: false
## Add Persistent Volumes Storage Class for corresponding cloud provider (supported: in-tree OpenStack, Cinder CSI,
## AWS EBS CSI, Azure Disk CSI, GCP Persistent Disk CSI)
persistent_volumes_enabled: false

## Container Engine Acceleration
## Enable container acceleration feature, for example use gpu acceleration in containers
# nvidia_accelerator_enabled: true
## Nvidia GPU driver install. Install will by done by a (init) pod running as a daemonset.
## Important: if you use Ubuntu then you should set in all.yml 'docker_storage_options: -s overlay2'
## Array with nvida_gpu_nodes, leave empty or comment if you don't want to install drivers.
## Labels and taints won't be set to nodes if they are not in the array.
# nvidia_gpu_nodes:
#   - kube-gpu-001
# nvidia_driver_version: "384.111"
## flavor can be tesla or gtx
# nvidia_gpu_flavor: gtx
## NVIDIA driver installer images. Change them if you have trouble accessing gcr.io.
# nvidia_driver_install_centos_container: atzedevries/nvidia-centos-driver-installer:2
# nvidia_driver_install_ubuntu_container: gcr.io/google-containers/ubuntu-nvidia-driver-installer@sha256:7df76a0f0a17294e86f691c81de6bbb7c04a1b4b3d4ea4e7e2cccdc42e1f6d63
## NVIDIA GPU device plugin image.
# nvidia_gpu_device_plugin_container: "registry.k8s.io/nvidia-gpu-device-plugin@sha256:0842734032018be107fa2490c98156992911e3e1f2a21e059ff0105b07dd8e9e"

## Support tls min version, Possible values: VersionTLS10, VersionTLS11, VersionTLS12, VersionTLS13.
# tls_min_version: ""

## Support tls cipher suites.
# tls_cipher_suites: {}
#   - TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA
#   - TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256
#   - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
#   - TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA
#   - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
#   - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
#   - TLS_ECDHE_ECDSA_WITH_RC4_128_SHA
#   - TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA
#   - TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA
#   - TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256
#   - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
#   - TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA
#   - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
#   - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
#   - TLS_ECDHE_RSA_WITH_RC4_128_SHA
#   - TLS_RSA_WITH_3DES_EDE_CBC_SHA
#   - TLS_RSA_WITH_AES_128_CBC_SHA
#   - TLS_RSA_WITH_AES_128_CBC_SHA256
#   - TLS_RSA_WITH_AES_128_GCM_SHA256
#   - TLS_RSA_WITH_AES_256_CBC_SHA
#   - TLS_RSA_WITH_AES_256_GCM_SHA384
#   - TLS_RSA_WITH_RC4_128_SHA

## Amount of time to retain events. (default 1h0m0s)
event_ttl_duration: "1h0m0s"

## Automatically renew K8S control plane certificates on first Monday of each month
auto_renew_certificates: false
# First Monday of each month
# auto_renew_certificates_systemd_calendar: "Mon *-*-1,2,3,4,5,6,7 03:00:00"

kubeadm_patches_dir: "{{ kube_config_dir }}/patches"
kubeadm_patches: []
# See https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/control-plane-flags/#patches
# Correspondance with this link
# patchtype = type
# target = target
# suffix -> managed automatically
# extension -> always "yaml"
# kubeadm_patches:
# - target: kube-apiserver|kube-controller-manager|kube-scheduler|etcd|kubeletconfiguration
#   type: strategic(default)|json|merge
#   patch:
#    metadata:
#      annotations:
#        example.com/test: "true"
#      labels:
#        example.com/prod_level: "{{ prod_level }}"
# - ...
# Patches are applied in the order they are specified.

# Set to true to remove the role binding to anonymous users created by kubeadm
remove_anonymous_access: false

```
[↩ back to YMLs list](#gv-list)
<a id="gv-containerd"></a>
### C) `inventory/mycluster/group_vars/containerd.yml`
```yaml
---
# inventory/mycluster/group_vars/all/containerd.yml
# Make containerd read per-registry hosts.toml files
containerd_registries_cfg_dir: "/etc/containerd/certs.d"

# Your Nexus base (HTTP)
nexus_host_with_port: "192.168.154.133:5000"

# === credentials (used in Authorization header) ===
nexus_user: "admin"         # <--- set yours
nexus_pass: "123"      # <--- set yours
nexus_auth_b64: "{{ (nexus_user + ':' + nexus_pass) | b64encode }}"

# DO NOT set deprecated auth vars; use headers below instead.

# === Mirrors for each upstream registry the cluster will pull from ===
# Shape REQUIRED by Kubespray/containerd:
# - prefix: "<upstream host>"
#   server: "https://<upstream host>"       # optional; defaults to https://<prefix>
#   mirrors:
#     - host: "http://<nexus>:<port>/<path-to-proxy-root>"
#       capabilities: ["pull", "resolve"]
#       skip_verify: true                   # safe for HTTP or self-signed TLS
#       override_path: true                 # REQUIRED because your proxy path includes /kubespray/<upstream>
#       header:
#         Authorization: ["Basic {{ nexus_auth_b64 }}"]   # remove this section if your Nexus is anonymous

containerd_registries_mirrors:
  - prefix: "192.168.154.133:5000"
    server: "http://192.168.154.133:5000" 
    mirrors:
      - host: "http://192.168.154.133:5000"
        capabilities: ["pull","resolve"]
        skip_verify: true
        override_path: true
        header:
          Authorization: ["Basic {{ nexus_auth_b64 }}"]

  # docker.io images via Nexus
  - prefix: "docker.io"
    server: "http://192.168.154.133:5000"
    mirrors:
      - host: "http://{{ nexus_host_with_port }}/kubespray/docker.io"
        capabilities: ["pull", "resolve"]
        skip_verify: true
        override_path: true
        header:
          Authorization: ["Basic {{ nexus_auth_b64 }}"]

  # registry.k8s.io (K8s core images) via Nexus
  - prefix: "registry.k8s.io"
    server: "http://192.168.154.133:5000"
    mirrors:
      - host: "http://{{ nexus_host_with_port }}/kubespray/registry.k8s.io"
        capabilities: ["pull", "resolve"]
        skip_verify: true
        override_path: true
        header:
          Authorization: ["Basic {{ nexus_auth_b64 }}"]

  # ghcr.io via Nexus
  - prefix: "ghcr.io"
    server: "http://192.168.154.133:5000"
    mirrors:
      - host: "http://{{ nexus_host_with_port }}/kubespray/ghcr.io"
        capabilities: ["pull", "resolve"]
        skip_verify: true
        override_path: true
        header:
          Authorization: ["Basic {{ nexus_auth_b64 }}"]

  # quay.io via Nexus
  - prefix: "quay.io"
    server: "http://192.168.154.133:5000"
    mirrors:
      - host: "http://{{ nexus_host_with_port }}/kubespray/quay.io"
        capabilities: ["pull", "resolve"]
        skip_verify: true
        override_path: true
        header:
          Authorization: ["Basic {{ nexus_auth_b64 }}"]

# Optional: ensure containerd looks at certs.d
containerd_config:
  version: 2
  plugins:
    "io.containerd.grpc.v1.cri":
      registry:
        config_path: "{{ containerd_registries_cfg_dir }}"

```

### D) Offline Lists (from contrib/offline)

#### Example of `files.list`
```text
[https://dl.k8s.io/release/v1.33.3/bin/linux/amd64/kubelet
https://dl.k8s.io/release/v1.33.3/bin/linux/amd64/kubectl
https://dl.k8s.io/release/v1.33.3/bin/linux/amd64/kubeadm
https://github.com/etcd-io/etcd/releases/download/v3.5.21/etcd-v3.5.21-linux-amd64.tar.gz
https://github.com/containernetworking/plugins/releases/download/v1.4.1/cni-plugins-linux-amd64-v1.4.1.tgz
https://github.com/projectcalico/calico/releases/download/v3.29.4/calicoctl-linux-amd64
https://github.com/projectcalico/calico/archive/v3.29.4.tar.gz
https://github.com/cilium/cilium-cli/releases/download/v0.18.5/cilium-linux-amd64.tar.gz
https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.33.0/crictl-v1.33.0-linux-amd64.tar.gz
https://storage.googleapis.com/cri-o/artifacts/cri-o.amd64.v1.33.2.tar.gz
https://get.helm.sh/helm-v3.18.4-linux-amd64.tar.gz
https://github.com/opencontainers/runc/releases/download/v1.3.0/runc.amd64
https://github.com/containers/crun/releases/download/1.17/crun-1.17-linux-amd64
https://github.com/youki-dev/youki/releases/download/v0.5.4/youki-0.5.4-x86_64-gnu.tar.gz
https://github.com/kata-containers/kata-containers/releases/download/3.7.0/kata-static-3.7.0-amd64.tar.xz
https://storage.googleapis.com/gvisor/releases/release/20250715.0/x86_64/runsc
https://storage.googleapis.com/gvisor/releases/release/20250715.0/x86_64/containerd-shim-runsc-v1
https://github.com/containerd/nerdctl/releases/download/v2.1.2/nerdctl-2.1.2-linux-amd64.tar.gz
https://github.com/containerd/containerd/releases/download/v2.1.3/containerd-2.1.3-linux-amd64.tar.gz
https://github.com/Mirantis/cri-dockerd/releases/download/v0.3.18/cri-dockerd-0.3.18.amd64.tgz
https://github.com/lework/skopeo-binary/releases/download/v1.16.1/skopeo-linux-amd64
https://github.com/mikefarah/yq/releases/download/v4.42.1/yq_linux_amd64
https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml](https://dl.k8s.io/release/v1.32.5/bin/linux/amd64/kubelet
https://dl.k8s.io/release/v1.32.5/bin/linux/amd64/kubectl
https://dl.k8s.io/release/v1.32.5/bin/linux/amd64/kubeadm
https://github.com/etcd-io/etcd/releases/download/v3.5.16/etcd-v3.5.16-linux-amd64.tar.gz
https://github.com/containernetworking/plugins/releases/download/v1.4.1/cni-plugins-linux-amd64-v1.4.1.tgz
https://github.com/projectcalico/calico/releases/download/v3.29.3/calicoctl-linux-amd64
https://github.com/projectcalico/calico/archive/v3.29.3.tar.gz
https://github.com/cilium/cilium-cli/releases/download/v0.18.3/cilium-linux-amd64.tar.gz
https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.32.0/crictl-v1.32.0-linux-amd64.tar.gz
https://storage.googleapis.com/cri-o/artifacts/cri-o.amd64.v1.32.0.tar.gz
https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz
https://github.com/opencontainers/runc/releases/download/v1.2.6/runc.amd64
https://github.com/containers/crun/releases/download/1.17/crun-1.17-linux-amd64
https://github.com/youki-dev/youki/releases/download/v0.5.3/youki-0.5.3-x86_64-gnu.tar.gz
https://github.com/kata-containers/kata-containers/releases/download/3.7.0/kata-static-3.7.0-amd64.tar.xz
https://storage.googleapis.com/gvisor/releases/release/20250512.0/x86_64/runsc
https://storage.googleapis.com/gvisor/releases/release/20250512.0/x86_64/containerd-shim-runsc-v1
https://github.com/containerd/nerdctl/releases/download/v2.0.5/nerdctl-2.0.5-linux-amd64.tar.gz
https://github.com/containerd/containerd/releases/download/v2.0.5/containerd-2.0.5-linux-amd64.tar.gz
https://github.com/Mirantis/cri-dockerd/releases/download/v0.3.17/cri-dockerd-0.3.17.amd64.tgz
https://github.com/lework/skopeo-binary/releases/download/v1.16.1/skopeo-linux-amd64
https://github.com/mikefarah/yq/releases/download/v4.42.1/yq_linux_amd64
https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml)

```

#### Example of `images.list`
```text
docker.io/mirantis/k8s-netchecker-server:v1.2.2
docker.io/mirantis/k8s-netchecker-agent:v1.2.2
quay.io/coreos/etcd:v3.5.16
quay.io/cilium/cilium:v1.17.3
quay.io/cilium/operator:v1.17.3
quay.io/cilium/hubble-relay:v1.17.3
quay.io/cilium/certgen:v0.2.1
quay.io/cilium/hubble-ui:v0.13.2
quay.io/cilium/hubble-ui-backend:v0.13.2
quay.io/cilium/cilium-envoy:v1.32.5-1744305768-f9ddca7dcd91f7ca25a505560e655c47d3dec2cf
ghcr.io/k8snetworkplumbingwg/multus-cni:v4.1.0
docker.io/flannel/flannel:v0.22.0
docker.io/flannel/flannel-cni-plugin:v1.1.2
quay.io/calico/node:v3.29.3
quay.io/calico/cni:v3.29.3
quay.io/calico/kube-controllers:v3.29.3
quay.io/calico/typha:v3.29.3
quay.io/calico/apiserver:v3.29.3
docker.io/rajchaudhuri/weave-kube:2.8.7
docker.io/rajchaudhuri/weave-npc:2.8.7
docker.io/kubeovn/kube-ovn:v1.12.21
docker.io/cloudnativelabs/kube-router:v2.1.1
registry.k8s.io/pause:3.10
ghcr.io/kube-vip/kube-vip:v0.8.9
docker.io/library/nginx:1.27.4-alpine
docker.io/library/haproxy:3.1.3-alpine
registry.k8s.io/coredns/coredns:v1.11.3
registry.k8s.io/dns/k8s-dns-node-cache:1.25.0
registry.k8s.io/cpa/cluster-proportional-autoscaler:v1.8.8
docker.io/library/registry:2.8.1
registry.k8s.io/metrics-server/metrics-server:v0.7.0
registry.k8s.io/sig-storage/local-volume-provisioner:v2.5.0
docker.io/rancher/local-path-provisioner:v0.0.24
registry.k8s.io/ingress-nginx/controller:v1.12.1
docker.io/amazon/aws-alb-ingress-controller:v1.1.9
quay.io/jetstack/cert-manager-controller:v1.15.3
quay.io/jetstack/cert-manager-cainjector:v1.15.3
quay.io/jetstack/cert-manager-webhook:v1.15.3
registry.k8s.io/sig-storage/csi-attacher:v3.3.0
registry.k8s.io/sig-storage/csi-provisioner:v3.0.0
registry.k8s.io/sig-storage/csi-snapshotter:v5.0.0
registry.k8s.io/sig-storage/snapshot-controller:v7.0.2
registry.k8s.io/sig-storage/csi-resizer:v1.3.0
registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.4.0
registry.k8s.io/provider-os/cinder-csi-plugin:v1.30.0
docker.io/amazon/aws-ebs-csi-driver:v0.5.0
docker.io/kubernetesui/dashboard:v2.7.0
docker.io/kubernetesui/metrics-scraper:v1.0.8
quay.io/metallb/speaker:v0.13.9
quay.io/metallb/controller:v0.13.9
registry.k8s.io/kube-apiserver:v1.32.5
registry.k8s.io/kube-controller-manager:v1.32.5
registry.k8s.io/kube-scheduler:v1.32.5
registry.k8s.io/kube-proxy:v1.32.5

```

### E) Helper Scripts (verbatim)

[↩ back to downloader scripts list](#dowloader-scripts-list)
<a id="download-files"></a>
#### `files.sh`
```bash
#!/bin/bash

CURRENT_DIR=$( dirname "$(readlink -f "$0")" )
OFFLINE_FILES_DIR_NAME="offline-files"
OFFLINE_FILES_DIR="${CURRENT_DIR}/${OFFLINE_FILES_DIR_NAME}"
OFFLINE_FILES_ARCHIVE="${CURRENT_DIR}/offline-files.tar.gz"
FILES_LIST=${FILES_LIST:-"${CURRENT_DIR}/kubespray/contrib/offline/tmp/files.list"}

# Ensure the files list exists
if [ ! -f "${FILES_LIST}" ]; then
    echo "${FILES_LIST} should exist, run ./generate_list.sh first."
    exit 1
fi

# Clean up previous files and directories
rm -rf "${OFFLINE_FILES_DIR}"
rm     "${OFFLINE_FILES_ARCHIVE}"
mkdir  "${OFFLINE_FILES_DIR}"

# Download each file from the list
while read -r url; do
  if ! wget -x -P "${OFFLINE_FILES_DIR}" "${url}"; then
    exit 1
  fi
done < "${FILES_LIST}"

# Archive the downloaded files
tar -czvf "${OFFLINE_FILES_ARCHIVE}" "${OFFLINE_FILES_DIR_NAME}"

```
[↩ back to downloader scripts list](#dowloader-scripts-list)
<a id="download-images"></a>
#### `images.sh`
```bash
#!/usr/bin/env bash
set -Eeuo pipefail

NEXUS_REPO="192.168.10.1:4000/kubespray"   # registry/repo prefix
CURRENT_DIR="/opt"
IMAGES_LIST="${CURRENT_DIR}/kubespray-2.28.0/contrib/offline/temp/images.list"
IMAGES_DIR="${CURRENT_DIR}/container-images"
IMAGES_ARCHIVE="${CURRENT_DIR}/container-images.tar.gz"

# Ensure the images list exists
if [[ ! -f "$IMAGES_LIST" ]]; then
  echo "Missing $IMAGES_LIST – run ./generate_list.sh first." >&2
  exit 1
fi

# Clean workspace
rm -rf "$IMAGES_DIR"
mkdir -p "$IMAGES_DIR"
rm -f "$IMAGES_ARCHIVE"

# Normalize list: strip CRLF, drop comments/blanks
normalize() {
  sed -e 's/\r$//' -e 's/#.*$//' -e '/^[[:space:]]*$/d'
}

# Pull, retag to your Nexus namespace, and save each as its own .tar.gz
normalize < "$IMAGES_LIST" | while IFS= read -r image; do
  echo "==> Pulling: $image"
  docker pull "$image"

  # Compute repo + tag safely (supports digest inputs too)
  new_ref=""
  if [[ "$image" == *@* ]]; then
    # e.g., registry.k8s.io/pause@sha256:deadbeef...
    base="${image%@*}"        # before @
    digest="${image##*@}"     # after @
    # turn digest into a tag-like suffix
    tag="sha256-${digest#*:}"
    new_ref="${NEXUS_REPO}/${base}:${tag}"
  else
    # e.g., registry.k8s.io/kube-apiserver:v1.29.0
    base="${image%:*}"        # before last :
    tag="${image##*:}"        # after last :
    new_ref="${NEXUS_REPO}/${base}:${tag}"
  fi

  echo "==> Retagging -> $new_ref"
  docker tag "$image" "$new_ref"  # ensure tag exists explicitly

  # Save to gz
  safe_name="$(printf '%s' "$new_ref" | sed 's#[/:@]#-#g')"
  echo "==> Saving: $new_ref -> $IMAGES_DIR/${safe_name}.tar.gz"
  docker save "$new_ref" | gzip > "$IMAGES_DIR/${safe_name}.tar.gz"

  # Optional: drop the original tag (keeps layers if still referenced)
  docker rmi "$image" || true
done

# Single archive (optional; else you can keep per-image tars)
tar -cvzf "$IMAGES_ARCHIVE" -C "$IMAGES_DIR" .

echo "Done. Per-image tars in $IMAGES_DIR, bundle at $IMAGES_ARCHIVE"
```
[↩ back to downloader scripts list](#dowloader-scripts-list)
<a id="download-left-over-images"></a>
#### `images-test.sh`
```bash
NEXUS_REPO="172.20.117.211:7051/kubespray"
IMAGES_LIST="/opt/kubespray/images.list"
OUT="/opt/missing_images.txt"

mapfile -t missing < <(
  sed -e 's/\r$//' -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$IMAGES_LIST" \
  | awk 'NF' \
  | while read -r img; do
      docker image inspect "$img" >/dev/null 2>&1 \
      || docker image inspect "${NEXUS_REPO}/${img}" >/dev/null 2>&1 \
      || echo "$img"
    done
)

printf '%s\n' "${missing[@]}" | tee "$OUT"
echo "Missing: ${#missing[@]}   (saved to $OUT)"


```

[↩ back to Push RPMs section](#back-to-files-push-repo)
<a id="files-push-repo"></a>
#### `files-push-repo.sh`
```bash
#!/bin/bash
# Nexus Yum Repository Multi-Directory Uploader (RPMs + optional repodata) with Resume Support

## ========================
## CONFIGURATION
## ========================
NEXUS_URL="http://192.168.154.133:8081/repository/local/"   # no trailing slash
NEXUS_USER="admin"
NEXUS_PASS="123"

# Each entry: "local_path nexus_repo_name"
REPOS=(
  "/opt/mnt/appstream             AppStream"
  "/opt/mnt/baseos                BaseOS"
  "/opt/mnt/epel                  EPEL"
  "/opt/mnt/epel-cisco-openh264   Epel-Cisco-Openh264"
  "/opt/mnt/extras                Extras"
  "/opt/mnt/docker-ce-stable      Docker-Ce-Stable"
)

INCLUDE_REPODATA=true                 # set false to skip repodata
BATCH_SIZE=500
SLEEP_BETWEEN_BATCHES=10
LOG_FILE="uploaded_files.log"
## ========================

set -o pipefail
touch "$LOG_FILE"

upload_file() {
  local file="$1"
  local repo_name="$2"
  local base_dir="$3"

  # relative path (preserve Packages/… and repodata/…)
  local rel_path="${file#$base_dir/}"

  # already uploaded?
  if grep -Fxq "$repo_name/$rel_path" "$LOG_FILE"; then
    echo "✅ Skipping (already uploaded): $repo_name/$rel_path"
    return 0
  fi

  local target_url="$NEXUS_URL/$repo_name/$rel_path"

  echo "⬆️  Uploading to [$repo_name]: $rel_path"
  # retry a few times; treat non-2xx as failure
  http_code=$(
    curl -sS --fail --retry 5 --retry-delay 2 \
      -u "$NEXUS_USER:$NEXUS_PASS" \
      --upload-file "$file" \
      -o /dev/null -w "%{http_code}" \
      "$target_url" || echo "000"
  )

  if [[ "$http_code" =~ ^20[0-9]$ ]]; then
    echo "$repo_name/$rel_path" >> "$LOG_FILE"
    echo "✅ Uploaded: $repo_name/$rel_path"
    return 0
  else
    echo "❌ Failed ($http_code): $repo_name/$rel_path"
    return 1
  fi
}

for entry in "${REPOS[@]}"; do
  src_dir=$(echo "$entry" | awk '{print $1}')
  repo_name=$(echo "$entry" | awk '{print $2}')
  echo "📂 Processing local dir: $src_dir  →  Nexus repo: $repo_name"

  # queue RPMs
  mapfile -t files < <(find "$src_dir" -type f -name "*.rpm" | sort)

  # optionally queue repodata/* files
  if [[ "$INCLUDE_REPODATA" == true && -d "$src_dir/repodata" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$src_dir/repodata" -type f | sort)
  fi

  count=0
  for f in "${files[@]}"; do
    upload_file "$f" "$repo_name" "$src_dir"
    ((count++))
    if (( count % BATCH_SIZE == 0 )); then
      echo "⏳ Batch complete, sleeping $SLEEP_BETWEEN_BATCHES seconds…"
      sleep "$SLEEP_BETWEEN_BATCHES"
    fi
  done
done

echo "🎉 Finished. Successful uploads recorded in: $LOG_FILE"


```

<a id="sh-images-load-and-retag"></a>

[↩ back to load & retag & push section](#load-retag-push)
#### `images-load-and-retag.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   NEW_REGISTRY=192.168.154.133:5000 ./load-and-retag.sh /path/to/tars
# Optional envs:
#   PUSH=true           # also docker push the new tags
#   REMOVE_OLD_TAGS=true  # remove the old tags after retagging

SRC_DIR="${1:-.}"
NEW_REGISTRY="${NEW_REGISTRY:-}"
PUSH="${PUSH:-true}"
REMOVE_OLD_TAGS="${REMOVE_OLD_TAGS:-false}"

if [[ -z "$NEW_REGISTRY" ]]; then
  echo "ERROR: Set NEW_REGISTRY ("NEW_REGISTRY")"; exit 1
fi

command -v docker >/dev/null || { echo "ERROR: docker not found"; exit 1; }
HAS_JQ=true
command -v jq >/dev/null || HAS_JQ=false

shopt -s nullglob
mapfile -t TAR_FILES < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.tar' | sort)

if (( ${#TAR_FILES[@]} == 0 )); then
  echo "No .tar files found in: $SRC_DIR"
  exit 0
fi

echo "Found ${#TAR_FILES[@]} tar files. Target registry: $NEW_REGISTRY"
echo

for TAR in "${TAR_FILES[@]}"; do
  echo "==> Processing: $TAR"

  TAGS=()
  if $HAS_JQ; then
    # Extract tags from manifest.json inside the tar (no extraction to disk).
    # If your files are .tar.gz, change 'tar -xOf' to 'tar -xOzf'.
    if TAGS_TEXT=$(tar -xOf "$TAR" manifest.json 2>/dev/null | jq -r '.[].RepoTags[]?' | sed '/^null$/d' | sort -u); then
      readarray -t TAGS <<<"$TAGS_TEXT"
    fi
  fi

  if (( ${#TAGS[@]} == 0 )); then
    # Fallback: get tags from docker load output
    LOAD_OUT=$(docker load -i "$TAR" 2>&1)
    echo "$LOAD_OUT" | sed 's/^/    /'
    # Lines look like: "Loaded image: <repo>:<tag>"
    readarray -t TAGS < <(echo "$LOAD_OUT" | awk -F': ' '/Loaded image: /{print $2}' | sed 's/@.*$//' | sort -u)
  else
    # We already know tags; now actually load the image (quietly)
    docker load -i "$TAR" >/dev/null
    echo "    Loaded image with tags:"
    printf "    - %s\n" "${TAGS[@]}"
  fi

  if (( ${#TAGS[@]} == 0 )); then
    echo "    WARNING: No tags found for $TAR; skipping retag."
    continue
  fi

  for OLD_TAG in "${TAGS[@]}"; do
    # Only replace the registry part (up to the first '/')
    if [[ "$OLD_TAG" != */* ]]; then
      echo "    Skipping non-namespaced tag: $OLD_TAG"
      continue
    fi
    REST="${OLD_TAG#*/}"               # everything after the first '/'
    NEW_TAG="${NEW_REGISTRY}/${REST}"  # keep path & tag, change only registry

    echo "    Retag: $OLD_TAG  -->  $NEW_TAG"
    docker tag "$OLD_TAG" "$NEW_TAG"

    if [[ "$PUSH" == "true" ]]; then
      echo "    Pushing: $NEW_TAG"
      docker push "$NEW_TAG"
    fi

    if [[ "$REMOVE_OLD_TAGS" == "true" ]]; then
      echo "    Removing old tag: $OLD_TAG"
      docker rmi "$OLD_TAG" || true
    fi
  done

  echo
done

echo "Done."

```

---

## 11) Reference: What hosts.toml should look like (examples)

> These are **rendered by Kubespray** from your containerd vars. Verify after a run.

**`/etc/containerd/certs.d/registry.k8s.io/hosts.toml`**
```toml
server = "http://192.168.154.133:5000"
[host."http://192.168.154.133:5000"]
  capabilities = ["pull","resolve"]
  skip_verify = true
  override_path = true
  [host."http://192.168.154.133:5000".header]
    Authorization = ["Basic YWRtaW46MTIz"]
```

**`/etc/containerd/certs.d/docker.io/hosts.toml`**
```toml
server = "http://192.168.154.133:5000"
[host."http://192.168.154.133:5000/kubespray/docker.io"]
  capabilities = ["pull","resolve"]
  skip_verify = true
  override_path = true
  [host."http://192.168.154.133:5000/kubespray/docker.io".header]
    Authorization = ["Basic YWRtaW46MTIz"]
```

**`/etc/containerd/certs.d/ghcr.io/hosts.toml`**
```toml
server = "http://192.168.154.133:5000"
[host."http://192.168.154.133:5000/kubespray/ghcr.io"]
  capabilities = ["pull","resolve"]
  skip_verify = true
  override_path = true
  [host."http://192.168.154.133:5000/kubespray/ghcr.io".header]
    Authorization = ["Basic YWRtaW46MTIz"]
```

**`/etc/containerd/certs.d/quay.io/hosts.toml`**
```toml
server = "http://192.168.154.133:5000"
[host."http://192.168.154.133:5000/kubespray/quay.io"]
  capabilities = ["pull","resolve"]
  skip_verify = true
  override_path = true
  [host."http://192.168.154.133:5000/kubespray/quay.io".header]
    Authorization = ["Basic YWRtaW46MTIz"]
```

**`/etc/containerd/certs.d/registry.k8s.io/hosts.toml`**
```toml
server = "http://192.168.154.133:5000"
[host."http://192.168.154.133:5000/kubespray/registry.k8s.io"]
  capabilities = ["pull","resolve"]
  skip_verify = true
  override_path = true
  [host."http://192.168.154.133:5000/kubespray/registry.k8s.io".header]
    Authorization = ["Basic YWRtaW46MTIz"]
```

If your Nexus requires auth and you configured `containerd_registry_auth(s)`, containerd will use the stored credentials. Only if you _must_ force a header, you can use `containerd_custom_hosts_conf` to inject:
```toml
[host."http://192.168.154.133:5000".header]
  Authorization = "Basic <base64 user:pass>"
```

---

# _The End_
