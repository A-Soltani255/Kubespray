# Air-gapped & Hardened Kubernetes Cluster with Kubespray

This repository contains a detailed, practical runbook for building a **production-style, air-gapped, hardened Kubernetes cluster** using [Kubespray](https://github.com/kubernetes-sigs/kubespray).

📄 **Main document (start here)**  
👉 [Installing Air-gapped Hardened Kubernetes Cluster Using Kubespray](./Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md)

---

## What this project is

This is not a generic “hello k8s” guide.

It is a **real-world scenario** written as a step-by-step document:

- Installing and preparing Linux nodes for a multi-node Kubernetes cluster
- Designing and deploying a **highly available control plane**
- Working in an **air-gapped / restricted network**
- Building and using:
  - Local OS package repositories
  - A private container registry
- Deploying Kubernetes with **Kubespray** and a custom CNI
- Applying opinionated **hardening** and doing post-install **health checks**

Think of it as a **runbook** you can hand to another engineer and they can follow it end-to-end.

---

## Skills demonstrated

This repo is meant to showcase concrete DevOps / SRE skills around Kubernetes:

- **Cluster provisioning**
  - Using Kubespray to deploy a multi-node, HA cluster
  - Customising inventory and group variables for your own topology

- **Air-gapped operations**
  - Mirroring OS repositories and container images
  - Using internal registries instead of direct internet access

- **Security & hardening**
  - Baseline hardening for the OS and Kubernetes components
  - Reducing exposure in a restricted environment

- **Operations & reliability**
  - Verifying cluster health after install
  - Thinking in terms of repeatable procedures, not one-off commands

---

## How to use this repository

1. Open the main guide:  
   👉 [Installing Air-gapped Hardened Kubernetes Cluster Using Kubespray](./Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md)

2. Read the **assumptions/prerequisites** section and adapt:
   - OS family and version
   - Node IPs and hostnames
   - Network/firewall rules
   - Storage layout

3. Follow the steps in order on a **lab or test environment** first.

4. Once you’re comfortable with the flow, adapt:
   - Inventory files
   - Group vars
   - Registry / repository endpoints  
   to match your own organisation’s standards.

---

## Using this in a portfolio / LinkedIn context

This repository is intentionally documentation-focused so that reviewers can see:

- How you **structure and document** a complex technical procedure
- That you understand:
  - Air-gapped / offline constraints
  - HA Kubernetes cluster design
  - Kubespray-based provisioning
  - Security and operational considerations

You can link directly to this repo from LinkedIn or your CV to demonstrate **hands-on Kubernetes platform engineering**, not just theory.

---

## Repository contents

Current:

- `Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md`  
  End-to-end runbook for building an air-gapped, hardened Kubernetes cluster with Kubespray.

Planned (future) additions:

- Example inventories and group vars
- Helper scripts and one-liners
- Diagrams and troubleshooting appendices

---

Feedback and suggestions are welcome via issues or pull requests.
