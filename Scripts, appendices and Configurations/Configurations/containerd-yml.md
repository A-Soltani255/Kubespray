### `inventory/mycluster/group_vars/all/containerd.yml`
```yaml
---
# Please see roles/container-engine/containerd/defaults/main.yml for more configuration options

# containerd_storage_dir: "/var/lib/containerd"
# containerd_state_dir: "/run/containerd"
# containerd_oom_score: 0

# containerd_default_runtime: "runc"
# containerd_snapshotter: "native"

# containerd_runc_runtime:
#   name: runc
#   type: "io.containerd.runc.v2"
#   engine: ""
#   root: ""

# containerd_additional_runtimes:
# Example for Kata Containers as additional runtime:
#   - name: kata
#     type: "io.containerd.kata.v2"
#     engine: ""
#     root: ""

# containerd_grpc_max_recv_message_size: 16777216
# containerd_grpc_max_send_message_size: 16777216

# Containerd debug socket location: unix or tcp format
# containerd_debug_address: ""

# Containerd log level
# containerd_debug_level: "info"

# Containerd logs format, supported values: text, json
# containerd_debug_format: ""

# Containerd debug socket UID
# containerd_debug_uid: 0

# Containerd debug socket GID
# containerd_debug_gid: 0

# containerd_metrics_address: ""

# containerd_metrics_grpc_histogram: false

# Registries defined within containerd.
containerd_registries_mirrors:
 - prefix: docker.io
   mirrors:
    - host: http://192.168.154.133:5000
      capabilities: ["pull", "resolve"]
      skip_verify: false
 - prefix: quay.io
   mirrors:
    - host: http://192.168.154.133:5002
      capabilities: ["pull", "resolve"]
      skip_verify: false
 - prefix: registry.k8s.io
   mirrors:
    - host: http://192.168.154.133:5001
      capabilities: ["pull", "resolve"]
      skip_verify: false
 - prefix: ghcr.io
   mirrors:
    - host: http://192.168.154.133:5003
      capabilities: ["pull", "resolve"]
      skip_verify: false

# containerd_max_container_log_line_size: 16384

containerd_registry_auth:
  - registry: 192.168.154.133:5000
    username: admin
    password: admin
  - registry: 192.168.154.133:5001
    username: admin
    password: admin
  - registry: 192.168.154.133:5002
    username: admin
    password: admin
  - registry: 192.168.154.133:5003
    username: admin
    password: admin
