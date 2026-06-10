# Air-Gapped, Offline and Hardened Kubernetes with Kubespray

> A practical, end-to-end runbook for building a production-style Kubernetes cluster in a restricted or fully air-gapped environment using Kubespray, Rocky Linux, Nexus Repository Manager, containerd and Cilium.

This repository is a documentation and runbook project. It is not the upstream Kubespray project. The goal is to show how a real Kubernetes platform can be prepared, deployed, hardened and validated when direct Internet access is not available.

## Start here

| Resource | Link |
|---|---|
| Live documentation site | <https://a-soltani255.github.io/Kubespray/> |
| Main build guide | [Installing Air-Gapped Hardened Kubernetes Cluster Using Kubespray](./Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md) |
| Supporting material | [Scripts, appendices and Configurations](./Scripts,%20appendices%20and%20Configurations/) |
| Advanced runbooks | [GitHub Issues](https://github.com/A-Soltani255/Kubespray/issues) |

## What this project covers

This project documents a repeatable path for deploying Kubernetes with Kubespray in an offline environment. It focuses on the parts that usually break in real deployments:

- Preparing all required artifacts on an Internet-connected machine.
- Mirroring RPM repositories, Python wheels, Kubernetes binaries and container images.
- Seeding Nexus Repository Manager inside the offline network.
- Configuring containerd to pull images from internal registries only.
- Preparing Kubespray inventory and `group_vars` for a multi-node cluster.
- Separating management-plane and data-plane traffic.
- Using Cilium as the CNI.
- Applying baseline hardening and controlled image pull behavior.
- Validating the final cluster with concrete post-install checks.
- Capturing troubleshooting notes and day-2 operational procedures.

Treat this repository as a runbook: another engineer should be able to read it, adapt the values, and reproduce the same type of cluster without searching across many separate notes.

## Reference architecture

The current documentation is based on this reference scenario:

| Area | Value |
|---|---|
| Operating system | Rocky Linux 10 |
| Kubernetes deployment tool | Kubespray |
| Kubernetes runtime | containerd |
| CNI | Cilium |
| Offline artifact hub | Sonatype Nexus Repository Manager |
| OS package mirror | Nexus YUM hosted repository |
| Container image mirrors | Nexus Docker hosted repositories |
| Control-plane access | HAProxy VIP on `192.168.10.100:6443` |
| Network model | Separate management and Kubernetes data networks |

Example node layout from the runbook:

| Role | Hostname | Data IP | Management IP |
|---|---|---:|---:|
| Control plane | `master1.soltani.co` | `192.168.10.1` | `172.40.10.1` |
| Control plane | `master2.soltani.co` | `192.168.10.2` | `172.40.10.2` |
| Control plane | `master3.soltani.co` | `192.168.10.3` | `172.40.10.3` |
| Worker | `worker1.soltani.co` | `192.168.10.4` | `172.40.10.4` |
| Worker | `worker2.soltani.co` | `192.168.10.5` | `172.40.10.5` |
| Kubespray / automation host | `kubespray.soltani.co` | `192.168.10.10` | `172.40.10.10` |
| Nexus | `nexus.soltani.co` | `192.168.10.20` | `172.40.10.20` |
| API load balancer | `apiserver.soltani.co` | `192.168.10.100` | `172.40.10.100` |

> Replace all IP addresses, hostnames, ports, credentials and repository names before using this in another environment.

## Repository structure

```text
.
├── README.md
├── Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md
├── index.html
├── robots.txt
├── sitemap.xml
└── Scripts, appendices and Configurations/
    ├── Configurations/
    │   ├── containerd-yml.md
    │   ├── examples of offline lists.md
    │   ├── hardening-yaml.md
    │   ├── k8s-cluster-yml.md
    │   ├── k8s-net-custom-cni-yml.md
    │   └── offline-yml.md
    ├── Firewalld  Preparation/
    │   └── Firewalld Configuration.md
    ├── Nexus Preparation/
    │   └── Nexus Repository Manager for Air-Gapped Kubespray Deployments.md
    └── Scripts/
        ├── files-push-repo.sh
        ├── files.sh
        ├── images-load-and-retag.sh
        ├── images-verify.sh
        └── images.sh
```

## Documentation map

| Document | Purpose |
|---|---|
| [Main Kubespray build guide](./Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md) | Complete installation procedure from artifact preparation to final verification. |
| [Nexus preparation](./Scripts,%20appendices%20and%20Configurations/Nexus%20Preparation/Nexus%20Repository%20Manager%20for%20Air-Gapped%20Kubespray%20Deployments.md) | Build Nexus repositories for RPM packages, raw files and Docker images. |
| [Firewalld configuration](./Scripts,%20appendices%20and%20Configurations/Firewalld%20%20Preparation/Firewalld%20Configuration.md) | Kubernetes firewall zones, services, ipsets, rich rules, Cilium traffic and rollback notes. |
| [containerd variables](./Scripts,%20appendices%20and%20Configurations/Configurations/containerd-yml.md) | containerd mirror and runtime-related Kubespray configuration. |
| [offline variables](./Scripts,%20appendices%20and%20Configurations/Configurations/offline-yml.md) | Offline download URLs, artifact paths and repository endpoints. |
| [cluster variables](./Scripts,%20appendices%20and%20Configurations/Configurations/k8s-cluster-yml.md) | Core Kubernetes cluster settings. |
| [hardening variables](./Scripts,%20appendices%20and%20Configurations/Configurations/hardening-yaml.md) | Kubernetes hardening configuration and admission plugin controls. |
| [custom CNI variables](./Scripts,%20appendices%20and%20Configurations/Configurations/k8s-net-custom-cni-yml.md) | Custom CNI values and Helm chart repository settings. |
| [offline list examples](./Scripts,%20appendices%20and%20Configurations/Configurations/examples%20of%20offline%20lists.md) | Example `files.list` and `images.list` style references. |

## Helper scripts

| Script | Purpose |
|---|---|
| [`files.sh`](./Scripts,%20appendices%20and%20Configurations/Scripts/files.sh) | Download offline binary artifacts from Kubespray-generated file lists. |
| [`files-push-repo.sh`](./Scripts,%20appendices%20and%20Configurations/Scripts/files-push-repo.sh) | Push or stage downloaded files into the internal repository layout. |
| [`images.sh`](./Scripts,%20appendices%20and%20Configurations/Scripts/images.sh) | Pull and save container images on the Internet-connected preparation host. |
| [`images-load-and-retag.sh`](./Scripts,%20appendices%20and%20Configurations/Scripts/images-load-and-retag.sh) | Load saved images, retag them for internal Nexus repositories and prepare them for push. |
| [`images-verify.sh`](./Scripts,%20appendices%20and%20Configurations/Scripts/images-verify.sh) | Verify that required images exist and identify missing images before deployment. |

Review scripts before running them. They are examples for this lab scenario and may need changes for your registry URLs, credentials, repository names and version pins.

## Deployment flow

The high-level process is:

1. **Prepare online artifacts once**
   - Sync RPM repositories.
   - Download Kubespray.
   - Download Python wheels.
   - Generate Kubespray offline lists.
   - Pull and save all required container images.
   - Download Kubernetes, containerd, CNI and supporting binaries.

2. **Move artifacts into the offline network**
   - Transfer RPM archives, image archives, wheels and binaries.
   - Validate checksums where available.
   - Keep a versioned copy of the artifact set for future rebuilds.

3. **Seed Nexus**
   - Create YUM, raw and Docker hosted repositories.
   - Upload RPM metadata and packages.
   - Push retagged container images into their matching internal repositories.
   - Expose repository access through controlled internal endpoints.

4. **Prepare all nodes**
   - Configure hostnames, DNS or `/etc/hosts`.
   - Configure NTP or Chrony.
   - Disable swap.
   - Confirm SSH access from the Kubespray host.
   - Apply firewall rules or confirm external firewall enforcement.

5. **Configure Kubespray**
   - Set inventory hosts and groups.
   - Configure `offline.yml`, `containerd.yml`, `k8s-cluster.yml`, CNI values and hardening values.
   - Confirm that every URL points to internal repositories only.

6. **Deploy the cluster**
   - Run Kubespray from the automation host.
   - Watch for image pull, certificate, API, CNI and kubelet errors.
   - Fix configuration issues in inventory or group variables, then re-run safely.

7. **Verify and document the final state**
   - Confirm node readiness.
   - Confirm control-plane health.
   - Confirm Cilium and CoreDNS status.
   - Confirm all image pulls resolve through Nexus.
   - Capture final versions, configs and verification output.

## Basic usage

Clone the repository:

```bash
git clone https://github.com/A-Soltani255/Kubespray.git
cd Kubespray
```

Open the main runbook:

```bash
less Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md
```

Or browse the live documentation site:

```text
https://a-soltani255.github.io/Kubespray/
```

## Advanced runbooks

Some longer operational procedures are tracked as GitHub issues:

| Issue | Topic |
|---|---|
| [Issue #2](https://github.com/A-Soltani255/Kubespray/issues/2) | Removing `AlwaysPullImages` and enforcing `IfNotPresent` safely. |
| [Issue #3](https://github.com/A-Soltani255/Kubespray/issues/3) | Running Kubespray through GitLab CI/CD for controlled day-2 changes. |

## Safety notes

- Air-gapped does not automatically mean secure. You still need checksum validation, controlled artifact promotion, internal TLS, access control and auditability.
- Do not expose internal Nexus backend ports directly to clients. Use controlled frontend endpoints and restrict access by network policy or firewall.
- Do not commit real passwords, tokens, private keys, certificates or internal-only secrets.
- Do not blindly reuse the example IP addresses or DNS names in production.
- Test the full flow in a lab before using it for a real environment.
- Keep the exact artifact versions used for every deployment. Offline rebuilds are only reliable when the input artifact set is preserved.

## Skills demonstrated

This project demonstrates practical DevOps, SRE and platform engineering work:

- Kubernetes cluster provisioning with Kubespray and Ansible.
- Air-gapped artifact preparation and repository mirroring.
- Nexus repository design for RPM packages, raw files and container images.
- containerd registry mirror configuration.
- Cilium-based Kubernetes networking.
- HA control-plane design with a load-balanced API endpoint.
- Firewall zoning and controlled traffic flows.
- Kubernetes hardening and admission plugin management.
- Repeatable runbook writing, validation and troubleshooting.
- CI/CD-driven day-2 operations using GitLab.

## Portfolio note

This repository is intentionally documentation-heavy. It is suitable for showing hands-on Kubernetes platform engineering work because it includes architecture, implementation details, operational trade-offs, troubleshooting notes, scripts and validation steps.

For a CV or LinkedIn profile, describe it as:

> Built and documented an air-gapped, hardened Kubernetes deployment workflow using Kubespray, Nexus, containerd and Cilium, including offline artifact mirroring, cluster inventory design, firewall rules, hardening controls, verification checks and CI/CD-based day-2 operations.

## Feedback

Issues and pull requests are welcome. When suggesting changes, include:

- The affected document or script.
- The environment where the issue was seen.
- The exact command or configuration that failed.
- The expected result.
- The actual result and error output.
