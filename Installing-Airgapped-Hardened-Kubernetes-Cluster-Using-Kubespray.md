
# Air‑Gapped & Hardened Kubernetes with Kubespray — Complete Instruction
_Last updated: 2025-11-25 13:55:51 UTC_


## Introduction:
This document distills the experience I gained from building this scenario multiple times: a Kubernetes 1.32.5 cluster on Rocky Linux 9 in a fully air-gapped (offline) environment using Kubespray and Sonatype Nexus. It is based on repeated, real deployments and focuses on the meaningful, hard-earned details that matter in practice: mirroring RPMs and container images, staging Kubernetes binaries, configuring containerd with HTTP registry mirrors, pinning versions, disabling non-essential add-ons, and validating the final cluster.
My goal is to give you a reproducible, opinionated path that reflects what actually worked in practice—not just theory.

The environment used throughout:
- Control planes: master1 (`192.168.154.131`) master2 (`192.168.154.132`) master3 (`192.168.154.134`)
- Workers: worker1 (`192.168.154.135`), worker2 (`192.168.154.136`)
- Build/automation: kubespray (`192.168.154.137`) — also chould serves offline files over HTTP (`:8080`)
- Artifact hub: nexus (`192.168.154.133`) — YUM (hosted) for RPMs and Docker (hosted) registries on `:5000` `:5001` `:5002` `:5003` for images

> Design choices (and why):
>- Air-gapped: reduces supply-chain risk, satisfies compliance, and guarantees repeatable builds by eliminating “latest from the Internet”.
>- Kubespray: declarative, idempotent, and inventory-driven automation built on Ansible; easier to audit than ad-hoc kubeadm scripts.
>- containerd (+ nerdctl/ctr): the CNCF-blessed container runtime with clear, file-driven mirror and auth configuration.
>- Cilium (KDD mode): mature, simple underlay/overlay networking; no external datastore; offline artifacts are small and easy to mirror.
>- Core components only: apiserver, controller-manager, scheduler, etcd, kube-proxy, CoreDNS, Cilium node/controllers. We explicitly disable nginx-proxy, dns-autoscaler, metrics-server, Helm, etc., for a minimal, production-friendly baseline.

### What you will do (nature of the work)

#### 1. Prepare artifacts online (once, on an Internet-connected Rocky 9 box):
- Mirror OS RPMs (BaseOS/AppStream/EPEL/Docker CE) with reposync and archive them.
- Clone Kubespray, pre-download pip wheels for offline installs, and generate lists of required Kubernetes binaries and container images using contrib/offline.
- Pull and save all container images and gather all binaries (kubeadm/kubelet/kubectl, containerd/runc/nerdctl, crictl, CNI, etcd, Helm, Cilium).
#### 2. Seed Nexus in the offline LAN:
- Load the archived RPMs into a YUM (hosted) repo (preserving repodata/).
- Stand up a Docker (hosted) registry on `192.168.154.133:5000`, load all images, retag them under the required mirror namespaces, and push.
- Ensure every offline node has a local.repo pointing to Nexus and can dnf update without Internet.
#### 3. Stage files on the Kubespray VM and serve over HTTP:
- Place the offline binaries under /srv/offline-files/ following the exact paths Kubespray expects.
- Serve them with a tiny HTTP server (`python3 -m http.server 8080`).
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
- A locked set of versions (Kubernetes, containerd/runc, CNI, etcd, Helm, Cilium) and the offline directory structure Kubespray expects.
- Explicit containerd configuration to use HTTP mirrors and, if needed, Basic Auth, with examples of the rendered `hosts.toml` files.
- Minimal add-ons (CoreDNS + Cilium) and instructions to disable nginx-proxy and DNS autoscaler for a lean control plane.
- Troubleshooting drawn from real errors (HTTPS vs HTTP pulls, duplicate “v” in versions, archive vs file copy, kubeadm template validation, Cilium CRDs), with concrete fixes you can apply immediately.
- Verification and Day-2 guidance (node lifecycle, etcd backups, image checks, DNS sanity tests).


### Scope, assumptions, and success criteria

#### In scope
- Three control planes (etcd on all three) fronted by HAProxy at `192.168.154.137:6443`.
- Two worker nodes.
- Air-gapped build using Nexus (YUM + Docker hosted).
- `containerd` runtime with pull-through mirrors configured for HTTP on `192.168.154.133` `:5000` `:5001` `:5002` `:5003`.
- Cilium networking , CoreDNS, kube-proxy; no nginx-proxy, no dns-autoscaler, no metrics-server, no Helm.

#### Assumptions
- All nodes run Rocky 9; SELinux disabled (Kubespray manages policies).
- Time is synchronized; swap is disabled/masked.
- Passwordless SSH from the Kubespray VM to all cluster nodes.
- Adequate firewall allowances inside the cluster; external ingress/egress is not covered here.

#### Success looks like
- `kubectl get nodes` shows master1/master2/master3/worker1/worker2 Ready.
- Only core Pods are running in `kube-system` (apiserver, scheduler, controller-manager, etcd, kube-proxy, CoreDNS, Cilium).
- `nerdctl -n k8s.io pull 192.168.154.133:5000/kubespray/registry.k8s.io/kube-apiserver:v1.32.5` succeeds from any node (HTTP mirror working).
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
- ***CRDs:*** CustomResourceDefinitions; cilium-agent (DaemonSet) and cilium-operator manifests are applied as part of networking setup.
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
| kubespray | kubespray | 192.168.154.137 | It chould serves offline binaries over HTTP: `http://192.168.154.137:8080/` |
| haproxy   | haproxy   | 192.168.154.137 | Forward requests on port 6443 to port 6443 on the master nodes, and requests on ports 443 and 80 to ports 30081 and 30080 on the worker nodes, respectively. |
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


## 0.1) HAProxy (on the **Kubespray host** 192.168.154.137)

HAProxy provides a single, stable control-plane endpoint and L4 pass-through for app NodePorts. In this setup, HAProxy runs **on the same VM as Kubespray** (`192.168.154.137`). 

I only used a single HAProxy here to keep this scenario closer to reality. I didn’t implement HAProxy with Keepalived when I set up this scenario multiple times, because all of that infrastructure was using a VIP, so I didn’t need to load balance requests to the master and worker nodes. Instead, I asked the network administrator to forward the requests as follows: traffic to VIP port 6443 → master nodes on port 6443, VIP port 443 → worker nodes on port 30081, VIP port 80 → worker nodes on port 30080, and VIP port 30088 → worker nodes on port 30088.

So, you should first decide whether you already have any technology in place to forward these requests, and then decide whether you need to use HAProxy/Keepalived or not.

### Do on 192.168.154.137

```bash
# 1) Install + enable HAProxy
sudo dnf -y install haproxy
sudo systemctl enable --now haproxy

# 2) Open firewall for API + HTTP/HTTPS + custom TCP 30088
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-port=6443/tcp
sudo firewall-cmd --permanent --add-port=30088/tcp
sudo firewall-cmd --reload

# (SELinux) allow outbound connects from haproxy if enforcing
# sudo setsebool -P haproxy_connect_any 1

# 3) Write haproxy.cfg (exactly your config)
sudo tee /etc/haproxy/haproxy.cfg >/dev/null <<'EOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 10000
    tune.ssl.default-dh-param 2048

defaults
    log     global
    mode    tcp                 # L4 passthrough
    option  dontlognull
    option  tcp-smart-accept
    option  tcp-smart-connect
    timeout connect 5s
    timeout client  60s
    timeout server  60s
    retries 3

# --- FRONTENDS ---
# 1) Kubernetes API: 6443 -> controllers:6443
frontend fe_k8s_api
    bind *:6443
    default_backend be_k8s_api

# 2) HTTPS apps: 443 -> workers:30081
frontend fe_https
    bind *:443
    default_backend be_https_nodeport

# 3) HTTP apps: 80 -> workers:30080
frontend fe_http
    bind *:80
    default_backend be_http_nodeport

# 4) TCP pass-through 30088 -> workers:30088
frontend fe_30088
    bind *:30088
    default_backend be_30088_nodeport

# --- BACKENDS ---
# Controllers (API server)
backend be_k8s_api
    balance roundrobin
    option  tcp-check
    server master1 192.168.154.131:6443 check
    server master2 192.168.154.132:6443 check
    server master3 192.168.154.134:6443 check

# Workers HTTPS NodePort (usually ingress HTTPS)
backend be_https_nodeport
    balance roundrobin
    option  tcp-check
    server worker1 192.168.154.135:30081 check
    server worker2 192.168.154.136:30081 check

# Workers HTTP NodePort (usually ingress HTTP)
backend be_http_nodeport
    balance roundrobin
    option  tcp-check
    server worker1 192.168.154.135:30080 check
    server worker2 192.168.154.136:30080 check

# Workers on NodePort 30088
backend be_30088_nodeport
    balance roundrobin
    option  tcp-check
    default-server inter 5s fall 3 rise 2
    server worker1 192.168.154.135:30088 check
    server worker2 192.168.154.136:30088 check
EOF

# 4) Restart and check status
sudo systemctl restart haproxy
sudo systemctl status haproxy --no-pager

# 5) Point Kubernetes at the LB (Kubespray group_vars)
#    Ensure these are present in inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml
sudo sed -i '/^apiserver_loadbalancer_domain_name:/d' inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml
sudo sed -i '/^apiserver_loadbalancer_port:/d' inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml
printf "apiserver_loadbalancer_domain_name: 192.168.154.137\napiserver_loadbalancer_port: 6443\n" | sudo tee -a inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml

# (Optional) fix comment in SANs: mark 192.168.154.137 as LB/HAProxy
# and ensure 192.168.154.137 remains listed under supplementary_addresses_in_ssl_keys
```

#### Token-by-token breakdown + safety notes

* `dnf -y install haproxy`

  * `dnf` (package manager), `-y` auto-answers yes, installs HAProxy RPM.
  * **Safety:** confirm repo trust; you already mirror RPMs via Nexus—stick to those repos to stay air-gapped. 
* `systemctl enable --now haproxy`

  * `enable` autostarts on boot; `--now` starts immediately.
* `firewall-cmd --permanent --add-service=https|http`

  * Opens 443/80. `--permanent` persists across reloads; follow with `--reload` to apply.
* `--add-port=6443/tcp`, `--add-port=30088/tcp`

  * Opens L4 pass-through ports for API and your custom TCP service.
  * **Safety:** scope traffic using zones/sources if this host is reachable from outside the cluster.
* `setsebool -P haproxy_connect_any 1` *(optional)*

  * Allows HAProxy to connect out to any port/domain. Required in some enforcing SELinux policies.
* `tee /etc/haproxy/haproxy.cfg <<'EOF' ... EOF`

  * Overwrites config atomically. `<<'EOF'` (single-quoted heredoc) prevents shell expansion inside the block.
  * **Safety:** keep a backup: `sudo cp /etc/haproxy/haproxy.cfg{,.bak}` before replacing.
* Backends (`server <name> <ip:port> check`)

  * `check` enables TCP health checks (uses `option tcp-check`); unhealthy targets are removed from rotation.
  * **Safety:** ensure those controller/worker IPs are reachable from 192.168.154.137.
* `sed -i` lines + `printf … | tee -a`

  * Ensures `apiserver_loadbalancer_domain_name: 192.168.154.137` and `apiserver_loadbalancer_port: 6443` are present; kubeconfig will point to the LB. Just clarify its comment to “LB/HAProxy IP.” 

**Common pitfalls**

* If your ingress controller doesn’t actually use NodePorts `30080/30081`, change the fe_http/fe_https backends to whatever NodePorts your ingress exposes.
* For long uploads / gRPC, bump `timeout client/server` (e.g., `5m`).
* If you later change master/worker IPs, update this file and restart HAProxy.



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
   firewall-cmd --zone=trusted --add-source=192.168.154.137 --permanent

   # Accept only cluster CIDRs (replace with your values)
   firewall-cmd --zone=trusted --add-source=10.233.64.0/18 --permanent
   firewall-cmd --zone=trusted --add-source=10.233.0.0/18 --permanent

   # Apply
   firewall-cmd --reload

   #Verfy your 
   firewall-cmd --list-sources --zone=trusted
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
5. **Passwordless SSH** from the Kubespray node to all cluster nodes (root or a sudoer).

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

alternatives --config python

# There are 2 programs which provide 'python'.
# 
#   Selection    Command
# -----------------------------------------------
#    1           /usr/bin/python3.12
# *+ 2           /usr/bin/python3.9
# 
# Enter to keep the current selection[+], or type selection number: 1

dnf install -y ansible

python -m venv /opt/ks-venv
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

- [`./files.sh`](./Scripts,%20appendices%20and%20Configurations/files.sh)                               # downloads all required binaries per files.list
- [`./images.sh`](./Scripts,%20appendices%20and%20Configurations/images.sh)                             # pulls & saves container images listed in images.list
- [`./images-verify.sh`](./Scripts,%20appendices%20and%20Configurations/images-verify.sh)               # optional validation of saved images and download the leftover images

> `images.sh` requires Docker to be running on the internet-connected VM. Note that the tag currently applied to images by the `images.sh` script is only a temporary identifier. In the future, each image will be pushed to its own private repository, based on the registry it comes from. We will not push all images to a single repository after extracting them. Instead, we will retag them according to the registry prefix. For example, images that start with `docker.io` or `ghcr.io` will receive different tags (as described earlier), mapped to the appropriate Nexus port for each registry. This way, each image is pushed to its corresponding private repository.

### 2.5 Seed **Nexus** with YUM + Docker hosted registries (in the offline LAN)

1) **Push RPMs**  
   - Copy `mnt.tar.gz` to Nexus and extract:
     
     ```bash
     tar xvzf mnt.tar.gz -C /opt
     ```
   - Use your helper to push packages + repodata into a YUM (hosted) repo (depth=1):
     [./files-push-repo.sh](./Scripts,%20appendices%20and%20Configurations/files-push-repo.sh)

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
     
     for h in 5000 5001 5002 5003; do docker login 192.168.154.133:$h; done
     systemctl daemon-reload
     systemctl restart docker

     ```
     
   - Load & retag & push:
     [./images-load-and-retag.sh](./Scripts,%20appendices%20and%20Configurations/images-load-and-retag.sh)
     
   This script re-tags images under `192.168.154.133:5000/kubespray/<upstream>/<image>:<tag>` and pushes them.

---

## 3) Kubespray Host (offline) — Stage binaries and serve via HTTP

1) Place the offline-files.tar.gz at `/srv`:
```
cd /srv
tar xvzf offline-files.tar.gz

/srv/offline-files/
  dl.k8s.io/release/v1.32.5/bin/linux/amd64/{kubeadm,kubelet,kubectl}
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
  dl.k8s.io/release/v1.32.5/bin/linux/amd64/{kubeadm,kubelet,kubectl}
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
for i in $FILES do; curl -v --user 'admin:admin' --upload-file $i http://192.168.154.133:8081/repository/${i}; done

# files_repo => http://192.168.154.133:8081/repository/raw

```
---

## 4) Kubespray Inventory / Python / Install

On the Kubespray host:
```bash
cd /opt
tar xvf kubespray-2.28.0.tar.gz

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
python3.12 -m pip install --no-index --find-links /opt/pip-req -r /opt/kubespray-2.28.0/requirements.txt

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

- With Kubespray, the inventory builder will make only the first IP a control-plane + etcd node by default and put the rest as workers. If you want multiple masters, you just edit the generated inventory to add those hosts to the `kube_control_plane` (and usually `etcd`) groups. So you should open `inventory/mycluster/inventory.ini` and put the extra masters under the `kube_control_plane` (and, typically, `etcd`) groups.
- etcd size should be odd (1, 3, 5…). For HA, use 3 etcd members—often colocated on the 3 masters.
- Masters are tainted by default (unschedulable); if you want them to run workloads, remove taints later.
- For multi-master you need a stable API endpoint. Either provide an external load balancer (VIP/DNS) to front the masters, or enable a built-in option (e.g., kube-vip/HAProxy depending on your Kubespray version) in group vars. Set the control-plane endpoint to that VIP/DNS before deploying.


Copy your prepared **group_vars** into place:

- [kubespray-2.28.0/inventory/mycluster/group_vars/offline.yml](./Scripts,%20appendices%20and%20Configurations/offline-yml.md)
- [kubespray-2.28.0/inventory/mycluster/group_vars/k8s-cluster.yml](./Scripts,%20appendices%20and%20Configurations/k8s-cluster-yml.md)
- [kubespray-2.28.0/inventory/shahkar/group_vars/k8s_cluster/k8s-net-custom-cni.yml](./Scripts,%20appendices%20and%20Configurations/k8s-net-custom-cni-yml.md)
- [kubespray-2.28.0/inventory/mycluster/group_vars/containerd.yml](./Scripts,%20appendices%20and%20Configurations/containerd-yml.md)

Also create your prepared **hardening.yaml** file in the root directory of the Kubespray project.
- [kubespray-2.28.0/hardening.yaml](./Scripts,%20appendices%20and%20Configurations/hardening-yaml.md)

#### Log visibility in Kubespray (`no_log` & `unsafe_show_logs`)
- `no_log` (Ansible): hides module args/results in output/logs. Ansible default is false, but Kubespray often sets `no_log: "{{ not (unsafe_show_logs | bool) }}"`, so the effective default is hidden.
- `unsafe_show_logs` (Kubespray): global switch (default false). Set to true to flip most Kubespray tasks to show full output (useful for deep debugging).
- How to enable (temporarily): per cluster in `inventory/mycluster/group_vars/all/all.yml` → `unsafe_show_logs: true`, or per run: `ansible-playbook … -e unsafe_show_logs=true -vvv`
- Security note: enabling exposes secrets (`tokens/passwords/certs`). Use briefly, then set back to `false` and scrub any captured logs.



Run the deployment at the root directory of the Kubespray project:
```bash
ansible-playbook -i inventory/shahkar/inventory.ini -e "@hardening.yaml" -b cluster.yml -vv
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
master2                    : ok=510  changed=48   unreachable=0    failed=0    skipped=882  rescued=0    ignored=1
master3                    : ok=510  changed=48   unreachable=0    failed=0    skipped=882  rescued=0    ignored=1
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
network_plugin/cilium : Cilium | Create cilium manifests ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ 3.68s
/opt/kubespray/roles/network_plugin/cilium/tasks/install.yml:382 ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
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
nerdctl -n k8s.io pull 192.168.154.133:5001/registry.k8s.io/kube-apiserver:v1.32.5
ctr -n k8s.io images ls | grep kube-apiserver
```

If you see `server ... does not seem to support HTTPS`, a host file is pointing to `https://` or your insecure registry list is missing the Nexus host:port. Ensure `server = "http://..."` and `skip_verify = true` in the generated `hosts.toml` files and that `192.168.154.133:5000` appears under `containerd_insecure_registries`.

---

## 6) Minimal Add‑ons Only (no nginx‑proxy, no dns‑autoscaler, etc.)

We keep only **kube‑apiserver, kube‑scheduler, kube‑controller‑manager, etcd, kube‑proxy, coredns, cilium-agent (DaemonSet) and cilium-operator**.

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

- **Cilium images/manifest not mirrored**
  - Ensure `cilium_crds_download_url` points at the Ciliuum tarball and the role extracts to a path Kubespray expects (we provide mapping in offline.yml).

- **Images fail to pull during bootstrap**
  - Test first with nerdctl: `nerdctl -n k8s.io pull <your-mirror>/<image>:<tag>`.

---

## 8) Post‑Install Verification

```bash
# 2) Cluster Status
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl -n kube-system get ds,deploy | awk 'NR==1 || /cilium|coredns|kube-/'
# 2) Container runtime
crictl info | head
ctr -n k8s.io images ls | head
# 3) DNS sanity
kubectl -n kube-system get svc kube-dns
kubectl run -it --rm --image=busybox:1.36 --restart=Never dns-test -- nslookup kubernetes.default

# 4) Cilium core components
kubectl -n kube-system get ds cilium
kubectl -n kube-system get deploy cilium-operator

# 5) All pods Ready?
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system get pods -l k8s-app=cilium-operator

# 6) Quick dataplane smoke test
kubectl run -n default -it --rm t1 --image=busybox:1.36 --restart=Never -- \
  sh -c 'ip a; nslookup kubernetes.default || true'

# 7) If kube-proxy kept + strict replacement used, watch for errors:
kubectl -n kube-system get ds kube-proxy || echo "kube-proxy disabled (OK for strict replacement)"

# 8) API through LB (expect TLS handshake / 403 when unauthenticated)
curl -vk https://192.168.154.137:6443/ -m 5 || true

# 9) NodePorts via LB
nc -vz 192.168.154.137 80
nc -vz 192.168.154.137 443
nc -vz 192.168.154.137 30088

# 10) kubeconfig should point at the LB now
kubectl cluster-info

# 11) Audit file exists and logs requests
sudo ls -lh /var/log/kube-apiserver-log.json
sudo tail -n2 /var/log/kube-apiserver-log.json

# 12) API server flags include admission config & encryption provider & TLS floor
ps aux | grep kube-apiserver | grep -E -- '--admission-control-config-file|--encryption-provider-config|--tls-min-version|--authorization-mode'

# 13) EventRateLimit config actually mounted
kubectl get --raw /configz | jq -r '.admissionControlConfiguration' | head || true

# 14) PSA 'restricted' enforced for new namespaces (privileged pod should be denied)
kubectl create ns psa-test
kubectl -n psa-test apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: p, annotations: { 'container.apparmor.security.beta.kubernetes.io/pod': 'unconfined' } }
spec: { containers: [ { name: c, image: busybox:1.36, securityContext: { privileged: true }, command: [ "sh","-c","sleep 3600" ] } ] }
EOF
# expect denial; then cleanup:
kubectl delete ns psa-test --ignore-not-found

# 15) Encryption at rest: new secret not visible in etcd strings
kubectl -n default create secret generic enc-test --from-literal=k=v$RANDOM
sudo strings /var/lib/etcd/member/snap/db | grep -m1 'enc-test' || echo "OK: not visible in plaintext"
kubectl -n default delete secret enc-test

# 16) Kubelet hardened: 10255 should be closed
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
nc -vz "$NODE_IP" 10255 || echo "10255 closed (good)"
```

Expected pods (steady state): apiserver/scheduler/controller-manager on masters; etcd on masters; coredns (2 replicas by default); cilium-node on each node; kube-proxy on each node; cilium-operator.

---

## 9) Day‑2 Notes (brief)

- **Add a worker:** put it in inventory, ensure OS prereqs + repo access, then `--limit <newnode> -b scale.yml`.
- **Remove a node:** `remove-node.yml` (cordon/drain first).
- **Back up etcd:** `ETCDCTL_API=3 etcdctl snapshot save /var/backups/etcd-$(date +%F).db` (run on etcd node).
- **Upgrades:** require pre-staging new images and binaries offline; follow Kubespray’s version constraints meticulously.

---

## 10) Reference: What hosts.toml should look like (examples)

> These are **rendered by Kubespray** from your containerd vars. Verify after a run.

**`/etc/containerd/certs.d/docker.io/hosts.toml`**
```toml
server = "https://docker.io"
[host."http://192.168.154.133:5000"]
  capabilities = ["pull","resolve"]
  skip_verify = false
  override_path = false
```

**`/etc/containerd/certs.d/ghcr.io/hosts.toml`**
```toml
server = "https://ghcr.io"
[host."http://192.168.154.133:5003"]
  capabilities = ["pull","resolve"]
  skip_verify = false
  override_path = false
```

**`/etc/containerd/certs.d/quay.io/hosts.toml`**
```toml
server = "https://quay.io"
[host."http://192.168.154.133:5002"]
  capabilities = ["pull","resolve"]
  skip_verify = false
  override_path = false
```

**`/etc/containerd/certs.d/registry.k8s.io/hosts.toml`**
```toml
server = "https://registry.k8s.io"
[host."http://192.168.154.133:5001"]
  capabilities = ["pull","resolve"]
  skip_verify = false
  override_path = false
```

---

# _The End_
