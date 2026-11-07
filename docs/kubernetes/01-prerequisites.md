# Kubernetes — Node Prerequisites

## Overview

Prepare three Ubuntu 24.04 virtual machines for a multi-node k3s Kubernetes cluster using Ansible.

## Cluster Architecture

| Hostname | IP Address | Role               |
|----------|------------|--------------------|
| k3s-control-1 | 10.20.0.10 | Control plane |
| k3s-worker-1 | 10.20.0.11 | Worker         |
| k3s-worker-2 | 10.20.0.12 | Worker         |

All nodes run on QEMU/KVM with a dedicated libvirt NAT network (`10.20.0.0/24`).

## Prerequisite Validation

Ansible playbook: `playbooks/verify-k3s-prerequisites.yml`

Checks performed:

- Ubuntu operating system (version is intentionally skipped)
- CPU, RAM, and kernel information
- Swap disabled
- Network interface configuration
- SSH and Ansible connectivity

**Result:** All three nodes passed the initial checks.

## Node Preparation

Ansible role: `roles/k3s-common/`

Responsibilities:

- Verify the operating system.
- Install required packages (`curl`, `ca-certificates`).
- Disable active swap.
- Disable swap entries in `/etc/fstab` to prevent reactivation on reboot.

### Why Disable Swap?

Kubernetes needs predictable memory management.

Swap can introduce unpredictable application latency and complicate memory-pressure handling. 
Although modern Kubernetes supports controlled swap configurations, I keep it disabled for simplicity and consistency.

## Execution

Validate prerequisites:

```bash
ansible-playbook -i inventories/host/hosts.yml \
  playbooks/verify-k3s-prerequisites.yml
```

Prepare nodes:

```bash
ansible-playbook -i inventories/host/hosts.yml \
  playbooks/prepare-k3s-nodes.yml
```

Verify idempotency by running the preparation playbook a second time and checking for `changed=0`.

## Status

- Prerequisite validation: **Passed**
- Node preparation: **Pending execution confirmation**
- k3s installation: **Not started**

