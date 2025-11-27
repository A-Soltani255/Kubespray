# Air-gapped Hardened Kubernetes Cluster with Kubespray

This repository contains a step-by-step guide for building a production-grade Kubernetes cluster in an air-gapped, security-focused environment using [Kubespray](https://github.com/kubernetes-sigs/kubespray).

📄 **Main document**  
[`Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md`](./Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md)

## What this guide covers

- Preparing Linux nodes for a multi-node Kubernetes cluster
- Designing and deploying a highly available control plane
- Building offline package and container registries for air-gapped installs
- Deploying Kubernetes with Kubespray using a custom CNI
- Hardening steps and basic post-install validation

The focus is on practical, repeatable steps that can be used as a runbook in enterprise environments.

## Who this is for

- DevOps / SRE / Platform engineers working in restricted or offline networks
- Teams that want to standardise how they bring up Kubernetes clusters with Kubespray
- Anyone looking for a detailed, narrative guide rather than a minimal quick-start

## How to use

1. Start with the main document:  
   - [Open the full guide](./Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md)
2. Follow the sections in order on a fresh set of nodes.
3. Adapt IP addresses, hostnames, and capacity planning to your own environment.
4. Use this repository as a reference in your CV / LinkedIn to demonstrate hands-on work with:
   - Air-gapped Kubernetes
   - Kubespray
   - Cluster hardening and operational practices

---

Feedback and suggestions are welcome via issues or pull requests.
