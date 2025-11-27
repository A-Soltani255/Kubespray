# Air-gapped & Hardened Kubernetes Cluster with Kubespray

This repository contains a detailed, practical runbook for building a **production-style, air-gapped, hardened Kubernetes cluster** using [Kubespray](https://github.com/kubernetes-sigs/kubespray).

📄 **Main document (start here)**  
👉 [Installing Air-gapped Hardened Kubernetes Cluster Using Kubespray](./Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md)

---

## What this project is

This is a **real-world scenario** written as a step-by-step document, not just a minimal quick-start.

The runbook shows how to:

- Install and prepare Linux nodes for a multi-node Kubernetes cluster
- Design and deploy a **highly available control plane**
- Work in an **air-gapped / restricted network**
- Build and use:
  - Local OS package repositories
  - A private container registry
- Deploy Kubernetes with **Kubespray** and a custom CNI
- Apply opinionated **hardening** and perform post-install **health checks**

Treat it as a **runbook**: something another engineer can follow end-to-end.

---

## Supporting material

Alongside the main runbook, this repo includes extra material in:

- `Scripts, appendices and Configurations/`  
  ([open folder](./Scripts,%20appendices%20and%20Configurations/))

That folder currently contains:

- **Example inventories and group vars**  
  To show how a Kubespray-based HA cluster can be modelled for this scenario.

- **Helper scripts and one-liners**  
  Commands you can reuse or adapt while following the guide (for setup, validation, etc.).

- **Diagrams and troubleshooting appendices**  
  Visuals and notes that explain the architecture and help debug common issues.

---

## Skills demonstrated

This repo is meant to showcase concrete DevOps / SRE skills around Kubernetes platform engineering:

- **Cluster provisioning**
  - Using Kubespray to deploy a multi-node, HA Kubernetes cluster
  - Customising inventory and group variables for your own topology

- **Air-gapped operations**
  - Mirroring OS repositories and container images
  - Using internal registries instead of direct internet access

- **Security & hardening**
  - Baseline hardening for the OS and Kubernetes components
  - Reducing exposure in restricted environments

- **Operations & reliability**
  - Verifying cluster health after install
  - Thinking in terms of repeatable procedures and scripts, not one-off commands

---

## How to use this repository

1. Open the main guide:  
   👉 [Installing Air-gapped Hardened Kubernetes Cluster Using Kubespray](./Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md)

2. Review and adapt the **assumptions/prerequisites**:
   - OS version
   - Node IPs and hostnames
   - Network/firewall rules
   - Storage layout

3. Follow the steps in order on a **lab or test environment** first.

4. Use the **Scripts, appendices and Configurations** folder for:
   - Ready-made inventories and group vars to speed up setup
   - Handy scripts while running the procedure
   - Diagrams and appendices when explaining or troubleshooting

5. Once you’re comfortable with the flow, adapt:
   - Inventory files
   - Group vars
   - Registry / repository endpoints  
   to match your organisation’s standards and security policies.

---

## Using this in a portfolio / LinkedIn context

This repository is intentionally documentation-heavy and scenario-based so that reviewers can see:

- How you **structure and document** a complex technical procedure
- That you understand:
  - Air-gapped / offline constraints
  - HA Kubernetes cluster design with Kubespray
  - Registry and repo mirroring
  - Basic hardening and operational practices

You can link directly to this repo from LinkedIn or your CV to demonstrate **hands-on Kubernetes platform engineering**, not just theory.

---

## Repository structure

- `Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md`  
  End-to-end runbook for building the air-gapped, hardened Kubernetes cluster with Kubespray.

- `Scripts, appendices and Configurations/`  
  Supporting material:
  - Example inventories and group vars  
  - Helper scripts and one-liners  
  - Diagrams and troubleshooting appendices

---

Feedback and suggestions are welcome via issues or pull requests.
