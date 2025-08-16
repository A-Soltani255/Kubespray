# Air‑Gapped Kubernetes with Kubespray — End‑to‑End Runbook
_Last updated: 2025-08-16 13:40:17 UTC_

This document is a complete, reproducible runbook to stand up a **Kubernetes 1.33.3** cluster in a fully offline (air‑gapped) environment using **Kubespray** + **Nexus** as both a YUM repository and a Docker registry mirror.

---

## 1) Topology & IP Plan

| Role        | Hostname  | IP              |
|-------------|-----------|-----------------|
| Master      | master1   | 192.168.154.134 |
| Worker      | worker1   | 192.168.154.135 |
| Worker      | worker2   | 192.168.154.136 |
| Kubespray   | kubespray | 192.168.154.137 |
| Nexus       | nexus     | 192.168.154.133 |

**Registries (on Nexus at :5000):**

- `192.168.154.133:5000/kubespray/docker.io`  
- `192.168.154.133:5000/kubespray/ghcr.io`  
- `192.168.154.133:5000/kubespray/quay.io`  
- `192.168.154.133:5000/kubespray/registry.k8s.io`

**Offline files web root (on Kubespray host):** `http://192.168.154.137:8080/`

**K8s CNI:** Calico (kdd CRDs)  
**CRI:** containerd

---

## 2) Online Preparation (do these on an internet‑connected Rocky 9 VM)

> These steps seed RPMs, Python wheels, Kubespray code, container images, and offline binaries.

### Step 1 — Seed RPM repositories (EPEL, Docker CE) and sync all packages

```bash
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
dnf install epel-release -y
dnf install yum-utils -y

# Sync all enabled repos to /mnt with metadata and only the newest packages
reposync -p /mnt --download-metadata --newest-only

# Archive for transfer to Nexus
tar cvzf mnt.tar.gz /mnt
```

**Why:** Nexus will serve as your offline YUM source. We export repodata intact so clients can use it immediately.

### Step 2 — Fetch Kubespray source and bundle it
```bash
dnf install git -y
cd /opt
git clone https://github.com/kubernetes-sigs/kubespray.git
tar cvzf kubespray.tar.gz kubespray
```

### Step 3 — Prepare Python 3.12, virtualenv, Ansible, and pip wheel cache
```bash
dnf install -y python3.12 python3.12-pip
alternatives --install /usr/bin/python3 python /usr/bin/python3.12 10
alternatives --install /usr/bin/python3 python /usr/bin/python3.9 20

dnf install ansible -y    # using online repos for convenience

python3 -m venv /opt/ks-venv
source /opt/ks-venv/bin/activate

# Download Python deps for Kubespray and twine into an offline cache
python3.12 -m pip download -r /opt/kubespray/requirements.txt -d /opt/pip-req
python3.12 -m pip download twine -d /opt/pip-req
tar cvfz pypi.tar.gz ./pip-req
```

**Why:** You’ll import this wheel cache on the Kubespray VM in the air‑gapped network.

### Step 4 — Generate Kubespray offline lists and download all images/files

On the online box where Kubespray was cloned:
```bash
cd /opt/kubespray/contrib/offline
./generate_list.sh

# Lists appear under: contrib/offline/tmp/{files.list, images.list}
# Use helper scripts to download everything:
./files.sh
./images.sh
# Optionally test images:
./images-test.sh
```

**Notes**
- images.sh requires Docker to be installed and running (for pull/save).  
- Binaries are laid out under a tree we’ll serve from the Kubespray host over HTTP.

### Step 5 — Seed Nexus (YUM + Docker hosted)

1) **On Nexus**, copy in mnt.tar.gz (from Step 1) and extract:
```bash
tar xvf mnt.tar.gz -C /
```
Run your helper to push RPMs + repodata into a **yum (hosted)** repo (depth=1):
```bash
./files-push-repo.sh
```

Distribute a local.repo file to **all offline machines** (including Nexus) under /etc/yum.repos.d/, pointing at your Nexus YUM URL(s). Then:
```bash
dnf clean all
dnf makecache
dnf update -y && dnf upgrade -y
```

2) **Docker (hosted) registry on Nexus**, then load & push all container images:

Install Docker **on the Nexus host** and allow plain HTTP to your hosted registry:
```bash
dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

# Add this flag to Docker's ExecStart (e.g., /etc/systemd/system/docker.service.d/custom.conf)
# --insecure-registry=192.168.154.133:5000

systemctl daemon-reload
systemctl restart docker
docker login 192.168.154.133:5000
```

Now run your image loader/retagger:
```bash
./images-load-and-retag.sh
```
This loads from tar archives, retags to 192.168.154.133:5000/kubespray/<upstream>/<name>:<tag> and pushes.

---

## 3) Kubespray VM (offline) — Stage binaries and serve them

1) Put your **offline files** under /srv/offline-files/ with this layout (examples):
```
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
  ...
```

2) Serve over HTTP (port 8080):
```bash
python3 -m http.server 8080 --directory /srv/offline-files
# files_repo will be http://192.168.154.137:8080
```

---

## 4) Kubespray inventory & Python environment

On the Kubespray VM, import Kubespray and wheels, then create inventory:

```bash
cd /opt
tar xvf kubespray.tar.gz
python3 -m venv /opt/ks-venv
source /opt/ks-venv/bin/activate
pip install --no-index --find-links /opt/pip-req -r /opt/kubespray/requirements.txt

cd /opt/kubespray
mkdir -p inventory/mycluster
declare -a IPS=(192.168.154.134 192.168.154.135 192.168.154.136)
CONFIG_FILE=inventory/mycluster/hosts.yaml \
python3 contrib/inventory_builder/inventory.py "${IPS[@]}"
```

> If you hit path issues for inventory.py, ensure you run the command **from** the Kubespray project root.

Populate inventory/mycluster/group_vars/ with your **offline.yml** and **k8s-cluster.yml** (see Appendices).

---

## 5) Containerd & Registry configuration (plain HTTP + Basic auth)

We use **containerd** + **nerdctl** and direct them to Nexus mirrors over HTTP.

### Key variables in offline.yml
- `containerd_registries_mirrors` → maps upstream domains to mirror URLs (HTTP).  
- `containerd_insecure_registries` → allows plain‑HTTP for your Nexus host.  
- `containerd_registry_auth` or `containerd_registry_auths` → credentials for docker login equivalent (if you require auth on the hosted repo).  
- `containerd_registry_custom_hosts` (Kubespray recent) or per‑domain hosts.toml snippets: we set `server="http://..."`, `capabilities=["pull","resolve"]`, `skip_verify=true`, and (optionally) the `Authorization` header if you want to force a specific Basic token in hosts.toml.

> With Kubespray’s variables, Basic auth is usually handled via the `auths` section, so you don’t need to inject an `Authorization` header manually. If you do want header injection, Kubespray supports templating of hosts.toml via `containerd_custom_hosts_conf` entries.

After a successful run, you should see files like:
```
/etc/containerd/certs.d/docker.io/hosts.toml
/etc/containerd/certs.d/registry.k8s.io/hosts.toml
/etc/containerd/certs.d/quay.io/hosts.toml
/etc/containerd/certs.d/ghcr.io/hosts.toml
```
Each pointing to your http://192.168.154.133:5000/kubespray/<upstream> mirror with skip_verify=true.

Validate:
```bash
nerdctl -n k8s.io pull 192.168.154.133:5000/kubespray/registry.k8s.io/kube-apiserver:v1.33.3
ctr -n k8s.io images ls | grep kube-apiserver
```

---

## 6) Disable extras (nginx‑proxy, DNS autoscaler, etc.)

We keep the cluster minimal: **apiserver, scheduler, controller‑manager, etcd, coredns, calico‑node/controllers, kube‑proxy**.

Set in k8s-cluster.yml:
```yaml
nginx_proxy_enable: false
dns_autoscaler_enabled: false
metrics_server_enabled: false
helm_enabled: false
# ...any other add‑ons you don’t want
```

If a prior run deployed them, prune:
```bash
kubectl -n kube-system delete ds -l k8s-app=nginx-proxy --ignore-not-found
kubectl -n kube-system delete deploy -l k8s-app=dns-autoscaler --ignore-not-found
```

---

## 7) Common pitfalls we solved (so you don’t have to)

- **HTTP vs HTTPS pulls failing** (`server ... does not seem to support HTTPS`):  
  Ensure `containerd_insecure_registries` includes `192.168.154.133:5000` and hosts.toml uses **http** with `skip_verify=true`. A quick smoke test with `nerdctl` must succeed **before** control plane comes up.

- **Undefined download.dest / download_cache_dir errors:**  
  Always define a single `downloads:` map with proper keys and ensure each has `url`, `dest`, `mode`, optional `checksum`, and `unarchive: true` when the file is an archive. Avoid duplicating `downloads:` blocks in the same YAML.

- **crictl & archive handling:**  
  `crictl-<ver>-linux-amd64.tar.gz` must be **unarchived** (either by Kubespray using `unarchive: true` or by you). The role expects to copy `/tmp/releases/crictl` → `/usr/local/bin/crictl` (binary inside archive).

- **etcd “double v” path:**  
  Keep filenames like `etcd-v3.5.21-linux-amd64.tar.gz`. If a task looks for `/tmp/releases/etcd-vv3.5.21-linux-amd64/...`, you’ve got a templating mismatch — fix your variable values to avoid a duplicated `v`.

- **kubeadm dest naming mismatch:**  
  Kubespray expects paths like `/tmp/releases/kubeadm-1.33.3-amd64`. If your file is simply `/tmp/releases/kubeadm`, add a `file` task to create a symlink or set the `dest` in `downloads.kubeadm` accordingly.

- **Calico CRDs (KDD) not found:**  
  Set `calico_crds_download_url` to the **Calico tarball** and ensure the role unpacks CRDs under a consistent directory (e.g., `/tmp/releases/calico-3.29.4-kdd-crds`) before concatenation. We provide a ready mapping in offline.yml.

- **Kubeadm config error** (`host '' must be a valid IP ...`):  
  Ensure `apiserver_loadbalancer_domain_name` is **unset** when you don’t have an external LB, and that `kube_apiserver_bind_address` is the master’s IP or a valid node address.

- **DNS autoscaler showing up:**  
  Set `dns_autoscaler_enabled: false` (Kubespray defaults sometimes enable it; we disable explicitly).

---

## 8) Deploy

From the Kubespray VM:
```bash
cd /opt/kubespray
source /opt/ks-venv/bin/activate
ansible-playbook -i inventory/mycluster/hosts.yaml -b cluster.yml
```

If resuming a failed run, you can target a task or a role using tags, but prefer to fix inputs and re‑run.

---

## 9) Post‑Install Checks

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
crictl ps -a | head
ctr -n k8s.io images ls | head

# DNS
kubectl -n kube-system get svc kube-dns
kubectl run -it --rm --image=busybox:1.36 --restart=Never dns-test -- nslookup kubernetes.default
```

You should only see the core components you opted in for.

---

## 10) Appendices

### A) inventory/mycluster/group_vars/offline.yml (effective version)

```yaml
---
# === Offline root served by your mini HTTP server ===
files_repo: "http://192.168.154.137:8080"

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
    groups:   [kube_control_plane]
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
    groups:   [kube_control_plane]
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
    groups:   [kube_control_plane]
    container: false
    url:      "{{ calicoctl_download_url }}"
    dest:     "{{ local_release_dir }}/{{ calicoctl_binary }}"
    mode:     "0755"
    checksum: "{{ calicoctl_checksum }}"

  calico_crds:
    enabled:  true
    groups:   [kube_control_plane]
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

### B) inventory/mycluster/group_vars/k8s-cluster.yml (effective version)

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

### C) Helper lists & scripts (verbatim)

Below are the artifacts you used during preparation; they’re embedded here for reference.

### files.list

```bash
https://dl.k8s.io/release/v1.33.3/bin/linux/amd64/kubelet
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
https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

```

### files.sh

```bash
#!/bin/bash

CURRENT_DIR=$( dirname "$(readlink -f "$0")" )
OFFLINE_FILES_DIR_NAME="offline-files"
OFFLINE_FILES_DIR="${{CURRENT_DIR}}/${{OFFLINE_FILES_DIR_NAME}}"
OFFLINE_FILES_ARCHIVE="${{CURRENT_DIR}}/offline-files.tar.gz"
FILES_LIST=${{FILES_LIST:-"${{CURRENT_DIR}}/kubespray/contrib/offline/tmp/files.list"}}

# Ensure the files list exists
if [ ! -f "${{FILES_LIST}}" ]; then
    echo "${{FILES_LIST}} should exist, run ./generate_list.sh first."
    exit 1
fi

# Clean up previous files and directories
rm -rf "${{OFFLINE_FILES_DIR}}"
rm     "${{OFFLINE_FILES_ARCHIVE}}"
mkdir  "${{OFFLINE_FILES_DIR}}"

# Download each file from the list
while read -r url; do
  if ! wget -x -P "${{OFFLINE_FILES_DIR}}" "${{url}}"; then
    exit 1
  fi
done < "${{FILES_LIST}}"

# Archive the downloaded files
tar -czvf "${{OFFLINE_FILES_ARCHIVE}}" "${{OFFLINE_FILES_DIR_NAME}}"

```

### files-push-repo.sh

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

upload_file() {{
  local file="$1"
  local repo_name="$2"
  local base_dir="$3"

  # relative path (preserve Packages/… and repodata/…)
  local rel_path="${{file#$base_dir/}}"

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
      -o /dev/null -w "%{{http_code}}" \
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
}}

for entry in "${{REPOS[@]}}"; do
  src_dir=$(echo "$entry" | awk '{{print $1}}')
  repo_name=$(echo "$entry" | awk '{{print $2}}')
  echo "📂 Processing local dir: $src_dir  →  Nexus repo: $repo_name"

  # queue RPMs
  mapfile -t files < <(find "$src_dir" -type f -name "*.rpm" | sort)

  # optionally queue repodata/* files
  if [[ "$INCLUDE_REPODATA" == true && -d "$src_dir/repodata" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$src_dir/repodata" -type f | sort)
  fi

  count=0
  for f in "${{files[@]}}"; do
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

### images.list

```bash
docker.io/mirantis/k8s-netchecker-server:v1.2.2
docker.io/mirantis/k8s-netchecker-agent:v1.2.2
quay.io/coreos/etcd:v3.5.21
quay.io/cilium/cilium:v1.17.3
quay.io/cilium/operator:v1.17.3
quay.io/cilium/hubble-relay:v1.17.3
quay.io/cilium/certgen:v0.2.1
quay.io/cilium/hubble-ui:v0.13.2
quay.io/cilium/hubble-ui-backend:v0.13.2
quay.io/cilium/cilium-envoy:v1.32.5-1744305768-f9ddca7dcd91f7ca25a505560e655c47d3dec2cf
ghcr.io/k8snetworkplumbingwg/multus-cni:v4.1.0
docker.io/flannel/flannel:v0.26.7
docker.io/flannel/flannel-cni-plugin:v1.7.1-flannel1
quay.io/calico/node:v3.29.4
quay.io/calico/cni:v3.29.4
quay.io/calico/kube-controllers:v3.29.4
quay.io/calico/typha:v3.29.4
quay.io/calico/apiserver:v3.29.4
docker.io/kubeovn/kube-ovn:v1.12.21
docker.io/cloudnativelabs/kube-router:v2.1.1
registry.k8s.io/pause:3.10
ghcr.io/kube-vip/kube-vip:v0.8.9
docker.io/library/nginx:1.28.0-alpine
docker.io/library/haproxy:3.1.7-alpine
registry.k8s.io/coredns/coredns:v1.12.0
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
registry.k8s.io/kube-apiserver:v1.33.3
registry.k8s.io/kube-controller-manager:v1.33.3
registry.k8s.io/kube-scheduler:v1.33.3
registry.k8s.io/kube-proxy:v1.33.3

```

### images.sh

```bash
#!/bin/bash

NEXUS_REPO="192.168.10.1:4000/kubespray" # Update this with your Nexus repository IP and port
CURRENT_DIR="/opt"
IMAGES_ARCHIVE="${{CURRENT_DIR}}/container-images.tar.gz"
IMAGES_DIR="${{CURRENT_DIR}}/container-images"
IMAGES_LIST="${{CURRENT_DIR}}/kubespray/contrib/offline/tmp/images.list"

# Ensure the images list exists
if [ ! -f "${{IMAGES_LIST}}" ]; then
    echo "${{IMAGES_LIST}} should exist, run ./generate_list.sh first."
    exit 1
fi

# Clean up previous images
rm -f  "${{IMAGE_TAR_FILE}}"
rm -rf "${{IMAGE_DIR}}"
mkdir  "${{IMAGE_DIR}}"

# Pull each image from the list
while read -r image; do
  if ! docker pull "${{image}}"; then
    exit 1
  fi
done < "${{IMAGES_LIST}}"

IMAGES=$(docker images --format "{{{{.Repository}}}}:{{{{.Tag}}}}")

# Tag and save each image to a tar.gz file
for i in $IMAGES;
do
  NEW_IMAGE=${{NEXUS_REPO}}/${{i}}
  TAR_FILE=$(echo ${{i}} | sed 's/[\/:]/-/g')
  docker tag $i ${{NEW_IMAGE}}
  docker rmi $i
  docker save ${{NEW_IMAGE}} | gzip > ${{IMAGES_DIR}}/${{TAR_FILE}}.tar.gz
done

# Archive the saved images
tar cvfz "${{IMAGES_ARCHIVE}}" "${{IMAGES_DIR}}"

```

### images-load-and-retag.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   NEW_REGISTRY=192.168.154.133:5000 ./load-and-retag.sh /path/to/tars
# Optional envs:
#   PUSH=true           # also docker push the new tags
#   REMOVE_OLD_TAGS=true  # remove the old tags after retagging

SRC_DIR="${{1:-.}}"
NEW_REGISTRY="${{NEW_REGISTRY:-}}"
PUSH="${{PUSH:-true}}"
REMOVE_OLD_TAGS="${{REMOVE_OLD_TAGS:-false}}"

if [[ -z "$NEW_REGISTRY" ]]; then
  echo "ERROR: Set NEW_REGISTRY ("NEW_REGISTRY")"; exit 1
fi

command -v docker >/dev/null || {{ echo "ERROR: docker not found"; exit 1; }}
HAS_JQ=true
command -v jq >/dev/null || HAS_JQ=false

shopt -s nullglob
mapfile -t TAR_FILES < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.tar' | sort)

if (( ${{#TAR_FILES[@]}} == 0 )); then
  echo "No .tar files found in: $SRC_DIR"
  exit 0
fi

echo "Found ${{#TAR_FILES[@]}} tar files. Target registry: $NEW_REGISTRY"
echo

for TAR in "${{TAR_FILES[@]}}"; do
  echo "==> Processing: $TAR"

  TAGS=()
  if $HAS_JQ; then
    # Extract tags from manifest.json inside the tar (no extraction to disk).
    # If your files are .tar.gz, change 'tar -xOf' to 'tar -xOzf'.
    if TAGS_TEXT=$(tar -xOf "$TAR" manifest.json 2>/dev/null | jq -r '.[].RepoTags[]?' | sed '/^null$/d' | sort -u); then
      readarray -t TAGS <<<"$TAGS_TEXT"
    fi
  fi

  if (( ${{#TAGS[@]}} == 0 )); then
    # Fallback: get tags from docker load output
    LOAD_OUT=$(docker load -i "$TAR" 2>&1)
    echo "$LOAD_OUT" | sed 's/^/    /'
    # Lines look like: "Loaded image: <repo>:<tag>"
    readarray -t TAGS < <(echo "$LOAD_OUT" | awk -F': ' '/Loaded image: /{{print $2}}' | sed 's/@.*$//' | sort -u)
  else
    # We already know tags; now actually load the image (quietly)
    docker load -i "$TAR" >/dev/null
    echo "    Loaded image with tags:"
    printf "    - %s\n" "${{TAGS[@]}}"
  fi

  if (( ${{#TAGS[@]}} == 0 )); then
    echo "    WARNING: No tags found for $TAR; skipping retag."
    continue
  fi

  for OLD_TAG in "${{TAGS[@]}}"; do
    # Only replace the registry part (up to the first '/')
    if [[ "$OLD_TAG" != */* ]]; then
      echo "    Skipping non-namespaced tag: $OLD_TAG"
      continue
    fi
    REST="${{OLD_TAG#*/}}"               # everything after the first '/'
    NEW_TAG="${{NEW_REGISTRY}}/${{REST}}"  # keep path & tag, change only registry

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

### images-test.sh

```bash
NEXUS_REPO="172.20.117.211:7051/kubespray"
IMAGES_LIST="/opt/kubespray/images.list"
OUT="/opt/missing_images.txt"

mapfile -t missing < <(
  sed -e 's/\r$//' -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$IMAGES_LIST" \
  | awk 'NF' \
  | while read -r img; do
      docker image inspect "$img" >/dev/null 2>&1 \
      || docker image inspect "${{NEXUS_REPO}}/${{img}}" >/dev/null 2>&1 \
      || echo "$img"
    done
)

printf '%s\n' "${{missing[@]}}" | tee "$OUT"
echo "Missing: ${{#missing[@]}}   (saved to $OUT)"


```

---

_End of runbook_
