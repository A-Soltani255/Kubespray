### A) Cluster Hardening Overrides — `hardening.yaml`

We layer security-focused overrides via a single file passed at runtime. It flips **audit logging on**, raises **TLS floors**, enables **admission plugins** (PodSecurity, EventRateLimit, AlwaysPullImages), turns on **encryption at rest**, and hardens **kubelet**. Your base doc keeps networking/mirrors/HAProxy/containers intact; this file just tightens security. 


#### Ccreate file + Run

```bash
# Create the overrides file next to your playbooks, at the root of the Kubespray project
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

#### Token-by-token breakdown (what/why/safety)

* `sudo tee hardening.yaml <<'YAML' … YAML`
  Writes the file atomically. Single-quoted heredoc prevents unwanted shell expansion in YAML.
* `authorization_modes: ['Node','RBAC']`
  Enforces RBAC; disables legacy permissive modes.
* `kubernetes_audit: true` + `audit_log_*`
  Turns on API auditing; your base doc had audit off—this explicitly flips it on. Logs go to `/var/log/kube-apiserver-log.json`. 
* `tls_min_version` / `tls_cipher_suites`
  Raises TLS floor and prunes weak suites. **Trade-off:** very old clients won’t connect.
* `kube_encrypt_secret_data: true`
  Enables Secret encryption at rest with `secretbox`. **Note:** plan key rotation before changing algorithms later.
* `kube_apiserver_enable_admission_plugins`

  * **PodSecurity**: enforces restricted defaults for new namespaces.
  * **EventRateLimit**: throttles abusive ns/users (protects API).
  * **AlwaysPullImages**: forces pulls at pod start. **Trade-off:** slightly slower starts; safe in your air-gapped mirror model. 
* `kube_apiserver_admission_control_config_file: true` + `…_event_rate_limits`
  Instructs Kubespray to render and wire the admission config file.
* `kube_controller_*` / `kube_scheduler_*` bind to `0.0.0.0`
  Makes health/metrics predictable; still gated by RBAC + network policy.
* `kube_read_only_port: 0`
  Closes the legacy kubelet 10255 endpoint.
* `kubelet_seccomp_default: true` / `kubelet_systemd_hardening: true`
  Applies safer defaults and stricter systemd unit policy.
* `kubelet_secure_addresses: "… 192.168.154.131 192.168.154.132 192.168.154.134"`
  **Fixed spacing bug**; restricts who can hit kubelet’s secure port. Pair with firewall rules.
* `ansible-playbook -e "@hardening.yaml"`
  Ansible reads the YAML and overlays these vars for this run only—clean separation from your base group_vars.  


#### Rollback / adjustments

* **Temporarily disable hardening:** run the same play **without** `-e "@hardening.yaml"` (fresh build), or comment specific keys in `hardening.yaml` and re-apply.
* **Tighten further:** uncomment `remove_anonymous_access: true` and add `--kubelet-certificate-rotation` flags if you want stricter defaults.
* **AlwaysPullImages side-effect:** if image churn hurts startup, drop it from the plugin list; you still have your Nexus mirrors for safe pulls. 
