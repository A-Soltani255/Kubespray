# Air-gapped, Offline & Hardened Kubernetes Cluster with Kubespray

This repository contains a detailed, practical runbook for building a
**production-style, air-gapped, offline, hardened Kubernetes cluster** using
[Kubespray](https://github.com/kubernetes-sigs/kubespray).

🌐 **Project landing page (GitHub Pages)**  
👉 https://a-soltani255.github.io/Kubespray/

📄 **Main document (start here)**  
👉 [Installing Air-gapped Hardened Kubernetes Cluster Using Kubespray](./Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md)

---

## What this project is

This is a **real-world scenario**, written as a step-by-step document – not just a
minimal quick-start.

The runbook shows how to:

- Install and prepare Linux nodes for a multi-node Kubernetes cluster
- Design and deploy a **highly available control plane**
- Work in an **air-gapped / offline / restricted network**
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
  - Using Kubespray (e.g. v2.28.0) to deploy a multi-node, HA Kubernetes cluster
  - Customising inventory and group variables for your own topology

- **Air-gapped & offline operations**
  - Mirroring OS repositories and container images
  - Using internal registries instead of direct Internet access
  - Handling “bastion” / transfer hosts for moving artifacts into restricted environments

- **Security & hardening**
  - Baseline hardening for the OS and Kubernetes components
  - Reducing exposure in restricted environments
  - Safely changing core behaviour such as image pull policies and admission plugins

- **Operations & reliability**
  - Verifying cluster health after install
  - Thinking in terms of repeatable procedures and scripts, not one-off commands

- **Automation & CI/CD (GitLab)**
  - Wiring a Kubespray-based cluster into GitLab CI/CD
  - Re-applying Kubespray via pipelines using Ansible tags for specific components (CNI, apps, etc.) :contentReference[oaicite:1]{index=1}  

---

## Deep-dive issues & advanced runbooks

Some of the more advanced procedures are written up as GitHub issues. These act as
extended runbooks for specific scenarios.

- **[Issue #2 – Removing AlwaysPullImages + Enforcing IfNotPresent](https://github.com/A-Soltani255/Kubespray/issues/2)**  
  Step-by-step runbook for going from “`AlwaysPullImages` is enabled” to
  “`AlwaysPullImages` fully removed and `IfNotPresent` under control”, including:

  - Cleaning Kubespray hardening/vars (`kube_apiserver_enable_admission_plugins`, `k8s_image_pull_policy: IfNotPresent`)  
  - Re-applying `cluster.yml` so kubeadm config is regenerated  
  - Updating kubeadm config + `kube-apiserver` manifests on each control-plane node  
  - Verifying that the admission plugin set and pull policy are correct across the cluster :contentReference[oaicite:2]{index=2}  

- **[Issue #3 – GitLab CI/CD for Kubespray-Based Kubernetes Cluster](https://github.com/A-Soltani255/Kubespray/issues/3)**  
  Full design and implementation guide for integrating this Kubespray project with
  GitLab CI/CD, including:

  - Keeping Kubespray + inventory in a GitLab project (e.g. `devops/kubespray`)  
  - Installing a GitLab Runner (binary, shell executor) on the Ansible host  
  - Defining jobs such as `kubespray-full`, `kubespray-cilium`, `kubespray-custom-cni`, etc.  
  - Having each job call `ci/run-kubespray.sh`, which runs  
    `ansible-playbook -i inventory/mycluster/inventory.ini cluster.yml [--tags ...]`  
  - Using SSH keys from the `gitlab-runner` user to reach all cluster nodes safely :contentReference[oaicite:3]{index=3}  

As the project evolves, additional improvements and day-2 operations may be tracked in
the [Issues tab](https://github.com/A-Soltani255/Kubespray/issues).

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

6. For advanced scenarios:
   - Use **Issue #2** if you need to change image pull policy / remove `AlwaysPullImages` safely  
   - Use **Issue #3** if you want to drive Kubespray re-applies via GitLab CI/CD pipelines

---

## Using this in a portfolio / LinkedIn context

This repository is intentionally documentation-heavy and scenario-based so that reviewers can see:

- How you **structure and document** a complex technical procedure
- That you understand:
  - Air-gapped / offline constraints
  - HA Kubernetes cluster design with Kubespray
  - Registry and repo mirroring
  - Baseline hardening and operational practices
  - CI/CD integration for day-2 cluster changes (via GitLab)

You can link directly to this repo — and to the live GitHub Pages site — from LinkedIn or your CV
to demonstrate **hands-on Kubernetes platform engineering**, not just theory.

---

## Repository structure

- `Installing-Airgapped-Hardened-Kubernetes-Cluster-Using-Kubespray.md`  
  End-to-end runbook for building the air-gapped, offline, hardened Kubernetes cluster with Kubespray.

- `Scripts, appendices and Configurations/`  
  Supporting material:
  - Example inventories and group vars  
  - Helper scripts and one-liners  
  - Diagrams and troubleshooting appendices

---

Feedback and suggestions are welcome via issues or pull requests.
