# Cluster Hardening Overrides — `hardening.yaml`

We layer security-focused overrides via a single file passed at runtime. It flips **audit logging on**, raises **TLS floors**, enables **admission plugins** (PodSecurity, EventRateLimit, AlwaysPullImages), turns on **encryption at rest**, and hardens **kubelet**. Your base doc keeps networking/mirrors/HAProxy/containers intact; this file just tightens security. 

---

## 1. The command itself (what you paste into the shell)

```bash
sudo tee hardening.yaml >/dev/null <<'YAML'
# Hardening
---
## kube-apiserver
authorization_modes: ['Node', 'RBAC']
# kube_apiserver_feature_gates: ['AppArmor=true']
kube_apiserver_request_timeout: 120s
kube_apiserver_service_account_lookup: true

# enable kubernetes audit
kubernetes_audit: true
audit_log_path: "/var/log/kube-apiserver-log.json"
audit_log_maxage: 30
audit_log_maxbackups: 10
audit_log_maxsize: 500

# TLS floor (cluster-wide knobs Kubespray wires into components)
tls_min_version: VersionTLS12
tls_cipher_suites:
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305

# enable encryption at rest (Secrets)
kube_encrypt_secret_data: true
kube_encryption_resources: [secrets]
kube_encryption_algorithm: "secretbox"

# Admission plugins
kube_apiserver_enable_admission_plugins:
  - EventRateLimit
  - AlwaysPullImages
  - ServiceAccount
  - NamespaceLifecycle
  - NodeRestriction
  - LimitRanger
  - ResourceQuota
  - MutatingAdmissionWebhook
  - ValidatingAdmissionWebhook
  - PodNodeSelector
  - PodSecurity

# Render admission control config (EventRateLimit policy)
kube_apiserver_admission_control_config_file: true
kube_apiserver_admission_event_rate_limits:
  limit_1:
    type: Namespace
    qps: 50
    burst: 100
    cache_size: 2000
  limit_2:
    type: User
    qps: 50
    burst: 100

kube_profiling: false
# remove_anonymous_access: true  # optional: uncomment to remove anon access

## kube-controller-manager
kube_controller_manager_bind_address: 0.0.0.0
kube_controller_terminated_pod_gc_threshold: 50
kube_controller_feature_gates: ["RotateKubeletServerCertificate=true"]

## kube-scheduler
kube_scheduler_bind_address: 0.0.0.0
# kube_scheduler_feature_gates: ["AppArmor=true"]

## etcd
etcd_deployment_type: host

## kubelet
kubelet_authorization_mode_webhook: true
kubelet_authentication_token_webhook: true
kube_read_only_port: 0
# kubelet_rotate_server_certificates: true
kubelet_protect_kernel_defaults: true
kubelet_event_record_qps: 1
# kubelet_rotate_certificates: true
kubelet_streaming_connection_idle_timeout: "5m"
kubelet_make_iptables_util_chains: true
kubelet_feature_gates: ["RotateKubeletServerCertificate=true"]
kubelet_seccomp_default: true
kubelet_systemd_hardening: true

# NOTE: fixed missing space between ...154.131 and ...154.132
kubelet_secure_addresses: "localhost link-local {{ kube_pods_subnet }} 192.168.154.137 192.168.154.131 192.168.154.132 192.168.154.134"

# tighten ownership
kube_owner: root
kube_cert_group: root

# Pod Security Admission: default 'restricted' for new namespaces
kube_pod_security_use_default: true
kube_pod_security_default_enforce: restricted
YAML
```

### Token-by-token breakdown

* `sudo`
  Run the following command as root. Needed because you want to write a file in the Kubespray directory (usually owned by a privileged user).

* `tee hardening.yaml`
  `tee` writes whatever it reads from stdin **to the file** `hardening.yaml` and normally also echoes it to stdout.

* `>/dev/null`
  Redirects `tee`’s stdout into the void.
  Result: file is created/overwritten, but nothing is printed to your terminal.

* `<<'YAML'`
  This starts a **here-doc**. Everything until a line containing only `YAML` is fed as stdin to `tee`.
  The single quotes around `YAML` → **no variable expansion** inside the block (e.g. `{{ kube_pods_subnet }}` stays literally that).

* `YAML` (final line)
  Terminates the here-doc.

**Safety / rollback**

* This **overwrites** any existing `hardening.yaml` in that directory.
  If you already have one:

  ```bash
  cp hardening.yaml hardening.yaml.bak.$(date +%F-%H%M)
  ```

* Verify file content:

  ```bash
  ls -l hardening.yaml
  sed -n '1,40p' hardening.yaml
  ```

---

## 2. How Kubespray uses this file (big picture)

Kubespray loads `hardening.yaml` as an **extra vars** file when you pass it with `-e @hardening.yaml` or via `-e "somevar=yes"` you include it in your play run. Typical:

```bash
ansible-playbook -i inventory/mycluster/hosts.yaml \
  cluster.yml \
  -e @hardening.yaml
```

These variables then modify:

* kube-apiserver flags
* controller-manager & scheduler flags
* kubelet config & systemd units
* TLS parameters
* Pod Security Admission defaults
* Encryption at rest & audit logging

So this is a “security opinion layer” sitting on top of your normal `group_vars`.

---

## 3. Section-by-section explanation

### 3.1. Header

```yaml
# Hardening
---
```

* Comment – just for humans.
* `---` marks the start of a YAML document.

---

### 3.2. kube-apiserver

```yaml
authorization_modes: ['Node', 'RBAC']
```

* Sets `--authorization-mode=Node,RBAC`
* `Node`: lets kubelets access the apiserver in a controlled way.
* `RBAC`: main authorization model; every API request checked against roles/rolebindings.
* Security-wise: **good default**; disables legacy ABAC.

---

```yaml
# kube_apiserver_feature_gates: ['AppArmor=true']
```

* Commented out. Would set `--feature-gates=AppArmor=true`.
* Only needed if using older K8s where AppArmor feature gate isn’t enabled by default.
* You left it commented → neutral.

---

```yaml
kube_apiserver_request_timeout: 120s
```

* Maps to `--request-timeout=120s`.
* Any API request taking >120s is terminated.
* Protects apiserver from hanging/very slow operations, avoids resource starvation.

Trade-off:
Too low → long-running list/watch operations could get cut off. 120s is fine for most.

---

```yaml
kube_apiserver_service_account_lookup: true
```

* `--service-account-lookup=true`
* When validating a service account token, apiserver **checks that the service account still exists**.
* Without this, deleted service accounts can still be used if you have a valid token.
* Security win; very small performance cost.

---

#### Audit logging

```yaml
kubernetes_audit: true
audit_log_path: "/var/log/kube-apiserver-log.json"
audit_log_maxage: 30
audit_log_maxbackups: 10
audit_log_maxsize: 500
```

* `kubernetes_audit: true`
  Tells Kubespray to enable **apiserver audit logging** (adds `--audit-log-*` flags and an audit policy).

* `audit_log_path`
  Where the audit log JSON file is written on control-plane nodes.

* `audit_log_maxage: 30`
  Keep rotated audit log files up to 30 days old.

* `audit_log_maxbackups: 10`
  Keep up to 10 rotated files.

* `audit_log_maxsize: 500`
  Max size (MB) before rotation: 500 MB.

Trade-offs & safety:

* Disk usage: audit logs can grow fast in chatty clusters → monitor `/var` disk.
* You probably want log shipping (e.g. fluent-bit) to central storage.
* Without audit logs, forensics and compliance are painful; this is a good hardening step.

---

#### TLS settings

```yaml
tls_min_version: VersionTLS12
tls_cipher_suites:
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
```

* `tls_min_version: VersionTLS12`
  Kubespray wires this into components as `--tls-min-version=VersionTLS12`.
  This **disables TLS 1.0 and 1.1**, forcing TLS 1.2+.

* `tls_cipher_suites`
  Restricts the cipher suites to a small set of modern ciphers:

  * ECDHE (perfect forward secrecy) + AES-GCM or CHACHA20-POLY1305.
  * These are broadly compliant with current security guidelines.

Trade-offs:

* Some ancient clients (old `curl`, old Java, legacy monitoring) might fail to connect.
* For a modern, internal K8s cluster this is typically safe and recommended.

---

#### Encryption at rest

```yaml
kube_encrypt_secret_data: true
kube_encryption_resources: [secrets]
kube_encryption_algorithm: "secretbox"
```

* `kube_encrypt_secret_data: true`
  Enables **encryption at rest** for API objects (backed by EncryptionConfiguration).

* `kube_encryption_resources: [secrets]`
  Only `Secret` objects stored in etcd are encrypted.
  (ConfigMaps etc. remain plaintext; you could add them, but it has compatibility implications.)

* `kube_encryption_algorithm: "secretbox"`
  Kubespray will configure a `secretbox` provider (NaCl secretbox, symmetric key).

Effects / trade-offs:

* Secrets are encrypted in etcd; an etcd disk dump is less useful to an attacker.
* Small performance overhead; usually not noticeable.
* **Important**: changing the algorithm later requires a key rotation / re-encrypt process. Don’t casually change these vars on an existing cluster.

---

#### Admission plugins

```yaml
kube_apiserver_enable_admission_plugins:
  - EventRateLimit
  - AlwaysPullImages
  - ServiceAccount
  - NamespaceLifecycle
  - NodeRestriction
  - LimitRanger
  - ResourceQuota
  - MutatingAdmissionWebhook
  - ValidatingAdmissionWebhook
  - PodNodeSelector
  - PodSecurity
```

Briefly what each does:

* `EventRateLimit`
  Limits the rate of `Event` objects → prevents etcd / apiserver spam.

* `AlwaysPullImages`
  Forces image pull on every pod start, even if present locally.

  * Security: prevents pods from using stale or local tampered images.
  * Trade-off: slower pod startup, more registry load.

* `ServiceAccount`
  Assigns service accounts and mounts their tokens. Essential; normally always enabled.

* `NamespaceLifecycle`
  Prevents using non-existing namespaces & handles deletion semantics.

* `NodeRestriction`
  Restricts what kubelets can modify (e.g. only their own Node and NodeLease). Critical for multi-tenant security.

* `LimitRanger`
  Enforces per-namespace default/maximum resource limits.

* `ResourceQuota`
  Enforces per-namespace quotas on CPU, memory, object counts, etc.

* `MutatingAdmissionWebhook` / `ValidatingAdmissionWebhook`
  Allows external webhooks to mutate & validate objects (e.g. Gatekeeper, Kyverno, custom policies).

* `PodNodeSelector`
  Enforces allowed `nodeSelector` usage from namespace annotations and/or global config.

* `PodSecurity`
  Built-in Pod Security Admission (successor to PodSecurityPolicy) – enforces `privileged`, `baseline`, `restricted` profiles using namespace labels.

Collectively, this is a strong, sensible baseline for a production cluster.

---

#### EventRateLimit config

```yaml
kube_apiserver_admission_control_config_file: true
kube_apiserver_admission_event_rate_limits:
  limit_1:
    type: Namespace
    qps: 50
    burst: 100
    cache_size: 2000
  limit_2:
    type: User
    qps: 50
    burst: 100
```

* `kube_apiserver_admission_control_config_file: true`
  Tell Kubespray to render an admission control config file (YAML) and wire it with `--admission-control-config-file`.

* Under `kube_apiserver_admission_event_rate_limits` you define 2 policies:

  * `limit_1`:

    * `type: Namespace` → rate limits based on namespace.
    * `qps: 50`, `burst: 100` → each namespace can emit 50 events/s with bursts up to 100.
    * `cache_size: 2000` → internal cache; too low can cause eviction; 2000 is sane.

  * `limit_2`:

    * `type: User` → per-user event rate limit.
    * Same QPS and burst.

Effect:

* Any misbehaving pod or controller spamming Events cannot bring etcd/apiserver to its knees.

Trade-off:

* If your cluster legitimately produces huge numbers of events (very large scale or very verbose controllers), you might need to tune these up.

---

#### Profiling & anonymous access

```yaml
kube_profiling: false
# remove_anonymous_access: true  # optional: uncomment to remove anon access
```

* `kube_profiling: false`
  Disables `--profiling` on components.

  * Removes access to `/debug/pprof` endpoints.
  * Security + simplicity: one less debug surface.

* `remove_anonymous_access` (commented)
  If enabled: `--anonymous-auth=false` on apiserver.

  * Means **no unauthenticated requests allowed at all**, even readonly.
  * Security: big win.
  * Trade-off: some unauthenticated health check patterns or old clients may break.
    You can enable this once you’re sure all access paths use proper auth.

---

### 3.3. kube-controller-manager

```yaml
kube_controller_manager_bind_address: 0.0.0.0
```

* Binds controller-manager HTTP endpoint to all interfaces.
* Depending on Kubespray version, this might be used for:

  * health endpoints (`/healthz`),
  * metrics (`/metrics`).

Security concern:
Exposing this on 0.0.0.0 is okay **if**:

* it’s only listening on localhost via kubelet proxy or behind firewall, or
* it’s TLS-protected and network-segmented.

If not, consider restricting to `127.0.0.1` and fronting it via kubelet or a sidecar.

---

```yaml
kube_controller_terminated_pod_gc_threshold: 50
```

* Sets `--terminated-pod-gc-threshold=50`.
* Once there are more than 50 terminated pods, controller-manager starts garbage-collecting them.
* This keeps etcd & apiserver from being flooded with dead pods.

Trade-off:

* Troubleshooting: fewer old pod objects to look at.
* You still have logs/metrics; 50 is small but okay for most namespaces.

---

```yaml
kube_controller_feature_gates: ["RotateKubeletServerCertificate=true"]
```

* Enables the feature gate for kubelet server cert rotation.
* Combined with kubelet-side flags, allows automatic rotation of their serving certificates.

---

### 3.4. kube-scheduler

```yaml
kube_scheduler_bind_address: 0.0.0.0
# kube_scheduler_feature_gates: ["AppArmor=true"]
```

* `kube_scheduler_bind_address: 0.0.0.0`
  Similar story: scheduler listens on all interfaces for metrics / health.
  Again: fine if network-segmented; otherwise you might want to restrict it.

* Feature gate line is commented; same idea as before.

---

### 3.5. etcd

```yaml
etcd_deployment_type: host
```

* Tells Kubespray to run etcd as **systemd-managed host processes**, not as static pods.
* Typical for Kubespray’s hardened setup.

Trade-offs:

* Pros:

  * Clear separation between control plane and etcd.
  * Easier to manage etcd versioning, OS-level security, backups (systemd + etcdctl).
* Cons:

  * Slightly more complex operationally compared to “control plane as pods”.

---

### 3.6. kubelet hardening

```yaml
kubelet_authorization_mode_webhook: true
kubelet_authentication_token_webhook: true
kube_read_only_port: 0
# kubelet_rotate_server_certificates: true
kubelet_protect_kernel_defaults: true
kubelet_event_record_qps: 1
# kubelet_rotate_certificates: true
kubelet_streaming_connection_idle_timeout: "5m"
kubelet_make_iptables_util_chains: true
kubelet_feature_gates: ["RotateKubeletServerCertificate=true"]
kubelet_seccomp_default: true
kubelet_systemd_hardening: true
```

Line-by-line:

* `kubelet_authorization_mode_webhook: true`
  Configure kubelet with `--authorization-mode=Webhook`.

  * Requests to kubelet are authorized via apiserver’s RBAC.
  * Prevents unauthenticated / unauthorized kubelet calls.

* `kubelet_authentication_token_webhook: true`
  `--authentication-token-webhook=true`

  * Kubelet validates bearer tokens by calling apiserver.
  * Prevents anonymous or spoofed tokens.

* `kube_read_only_port: 0`
  `--read-only-port=0`

  * Disables insecure HTTP port on kubelet (default 10255).
  * That port is historically a big security footgun → good to kill it.

* `kubelet_protect_kernel_defaults: true`
  `--protect-kernel-defaults=true`

  * Kubelet **refuses** to override kernel sysctls with pod annotations if they conflict with defaults.
  * Protects OS-level tuning; good in multi-tenant or strict environments.

* `kubelet_event_record_qps: 1`
  `--event-qps=1`

  * Limit kubelet to 1 event per second.
  * Very conservative; dramatically reduces event spam from kubelets.

  Trade-off:
  You might miss some per-pod event granularity under heavy churn (events get sampled).

* `kubelet_streaming_connection_idle_timeout: "5m"`
  `--streaming-connection-idle-timeout=5m`

  * Exec/attach/port-forward streams are closed after 5 minutes of idle.
  * Limits the time a compromised connection can hang around.

* `kubelet_make_iptables_util_chains: true`
  `--make-iptables-util-chains=true`

  * Kubelet is allowed to manage `KUBE-*` iptables chains.
  * Needed for normal K8s networking (clusterIP, NodePort, etc.).

* `kubelet_feature_gates: ["RotateKubeletServerCertificate=true"]`
  Enables feature gate for rotating kubelet serving certs.

* `kubelet_seccomp_default: true`
  Sets `seccompProfile.type: RuntimeDefault` for pods by default:

  * Pods run with a **default seccomp profile**, reducing syscall surface.
  * Some legacy containers that need weird syscalls may break → you’d then override with `unconfined` or a custom profile.

* `kubelet_systemd_hardening: true`
  Kubespray-specific: adds hardening options to the kubelet systemd unit, like:

  * `ProtectSystem=full`
  * `ProtectHome=true`
  * `NoNewPrivileges=true`
  * etc.
    It makes kubelet itself more sandboxed at the OS level.

---

#### kubelet secure addresses

```yaml
kubelet_secure_addresses: "localhost link-local {{ kube_pods_subnet }} 192.168.154.137 192.168.154.131 192.168.154.132 192.168.154.134"
```

Kubespray uses this to populate `--address` / `--tls-cert-file` SANs and similar. The string is a space-separated list:

* `localhost`
  Ensure kubelet’s TLS cert is valid for `localhost`.

* `link-local`
  Include link-local addresses.

* `{{ kube_pods_subnet }}`
  Jinja placeholder – stays literal here, but Kubespray will substitute the pod network CIDR.

* `192.168.154.137 192.168.154.131 192.168.154.132 192.168.154.134`
  Probably your control-plane / LB IPs.

**Important**:
If this list is wrong:

* kubelet might not listen on expected IPs.
* TLS SAN mismatch → clients get certificate errors when hitting kubelet via those IPs.

You fixed a missing space between `.131` and `.132` – good catch; otherwise it becomes a single invalid token.

---

### 3.7. Ownership tightening

```yaml
kube_owner: root
kube_cert_group: root
```

* `kube_owner: root`
  Files under `/etc/kubernetes` etc. owned by `root`.

* `kube_cert_group: root`
  Certificates are owned by group `root` as well (i.e., root:root).

Security effect:

* Only root can read key material & sensitive configs.
* If you wanted kubelet or some non-root user to access certs directly, you’d widen this; but from a hardening standpoint, root:root is ideal.

---

### 3.8. Pod Security Admission defaults

```yaml
kube_pod_security_use_default: true
kube_pod_security_default_enforce: restricted
```

Pod Security Admission (PSA) built-in policy:

* `kube_pod_security_use_default: true`
  Kubespray automatically labels **new namespaces** with PSA labels.

* `kube_pod_security_default_enforce: restricted`
  New namespaces get enforced with `restricted`:

  Equivalent to labels like:

  * `pod-security.kubernetes.io/enforce=restricted`
  * plus `version` etc.

What `restricted` implies (simplified):

* No privileged containers.
* No hostPath (or highly restricted).
* No hostPID / hostIPC / hostNetwork.
* Must set resource requests/limits (depending on version).
* Capabilities, sysctls, seccomp, etc. are tightly controlled.

Trade-offs:

* Great security baseline.
* Will break any workload that expects to run privileged, use hostNetwork, or mount arbitrary host paths.
  For such workloads, you’ll either:

  * create dedicated namespaces with `enforce=baseline` or `privileged`, or
  * set namespace labels manually to relax.

---

## 4. How to apply and verify

### Apply with Kubespray

```bash
cd /opt/kubespray  # or wherever your repo is

ansible-playbook -i inventory/mycluster/hosts.yaml \
  cluster.yml \
  -e @hardening.yaml
```

For upgrades, you usually rerun `cluster.yml` with updated vars; Kubespray reconciles components with new flags.

### Quick verification checklist

Some focused checks after deployment:

```bash
# 1) Check apiserver flags
kubectl -n kube-system get pods -l component=kube-apiserver -o wide
kubectl -n kube-system logs -l component=kube-apiserver | head

# or describe one static pod:
kubectl -n kube-system describe pod kube-apiserver-<node>

# 2) Audit log file exists on control-plane node
sudo ls -lh /var/log/kube-apiserver-log.json*
sudo tail -n 20 /var/log/kube-apiserver-log.json

# 3) TLS - check cipher support from a node (requires openssl 1.1+)
echo | openssl s_client -connect 127.0.0.1:6443 -tls1_1 2>/dev/null | grep -i "handshake failure" || echo "TLS1.1 maybe still allowed?"
echo | openssl s_client -connect 127.0.0.1:6443 -tls1_2 2>/dev/null | grep -i "Protocol"

# 4) Encryption at rest - ensure EncryptionConfiguration is present
sudo cat /etc/kubernetes/encryption-config.yaml || sudo find /etc/kubernetes -maxdepth 1 -name '*encrypt*'

# 5) Kubelet ports
sudo ss -lntp | egrep '10250|10255'

# Expect: 10250 open, 10255 CLOSED
# 6) PodSecurity: new namespace labels
kubectl create ns test-psa
kubectl get ns test-psa --show-labels
```

---

## 5. Trade-off summary

* **Stronger defaults**: TLS ≥1.2, encrypted Secrets, PSA=restricted, seccomp default, no insecure kubelet ports, audit on.
* **You pay in**:

  * Slight performance overhead (audit + encryption + stricter admission).
  * More friction for “hacky” workloads (privileged pods, hostPath, weird syscalls).
  * Need for careful monitoring (audit log size, disk space).

For a serious cluster like your Shahkar setup, this is a solid baseline. From here, the next layer is policy-as-code (OPA/Gatekeeper, Kyverno), network policy, and tightening identities (short-lived tokens, workload identity) – but this hardening.yaml is already a big move from “toy cluster” to “grown-up cluster.”
