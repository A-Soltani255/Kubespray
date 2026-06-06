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
  - prefix: "docker.io"
    mirrors:
      - host: "https://nexus.soltani.co:5000"
        capabilities: ["pull", "resolve"]
        skip_verify: false
        header:
          Authorization: "Basic a3ViZTpBU0R3c3gqJVFXRTEyMw=="
  - prefix: "registry.k8s.io"
    mirrors:
      - host: "https://nexus.soltani.co:5001"
        capabilities: ["pull", "resolve"]
        skip_verify: false
        header:
          Authorization: "Basic a3ViZTpBU0R3c3gqJVFXRTEyMw=="
  - prefix: "quay.io"
    mirrors:
      - host: "https://nexus.soltani.co:5002"
        capabilities: ["pull", "resolve"]
        skip_verify: false
        header:
          Authorization: "Basic a3ViZTpBU0R3c3gqJVFXRTEyMw=="
  - prefix: "ghcr.io"
    mirrors:
      - host: "https://nexus.soltani.co:5003"
        capabilities: ["pull", "resolve"]
        skip_verify: false
        header:
          Authorization: "Basic a3ViZTpBU0R3c3gqJVFXRTEyMw=="
