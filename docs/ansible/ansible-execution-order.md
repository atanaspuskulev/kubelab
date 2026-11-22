# Ansible Playbook Execution Order — kubelab

**Project:** `kubelab`  
**Environment:** Ubuntu hypervisor, KVM/libvirt, Ubuntu 24.04 Kubernetes VMs  
**Updated:** 22 November 2026  
**Scope:** Verified playbook entry points and recommended execution sequence based on the repository contents shared on 22 November 2026. Role internals are not exhaustively audited here.

## 1. Purpose

This runbook is the entry point for provisioning and configuring `kubelab` with Ansible. It distinguishes the **fresh deployment sequence**, **verification and safe reruns**, **future work**, and **destructive operations**. Run commands from the repository's `ansible/` directory.

The inventory is `inventories/host/hosts.yml`. The `hypervisors` group targets the physical hypervisor; `k8s_cluster` targets the three guest VMs; `k8s_servers` targets the control-plane VM.

## 2. Environment

| Host            | Address                                  | Inventory group / role        |
|-----------------|------------------------------------------|-------------------------------|
| `kubelab`       | Hypervisor address supplied by inventory | `hypervisors`                 |
| `k8s-control-1` | `10.20.0.10`                             | Control plane (`k8s_servers`) |
| `k8s-worker-1`  | `10.20.0.11`                             | Worker (`k8s_cluster`)        |
| `k8s-worker-2`  | `10.20.0.12`                             | Worker (`k8s_cluster`)        |

The guests use the libvirt network `k8s-lab` (`10.20.0.0/24`). Ansible SSH access to guests must work via the inventory's configured connection path (including any jump host).

## 3. Fresh deployment: recommended execution order

The following order follows the supplied playbook contents. It is the **recommended dependency sequence**, not a claim that a complete clean-room deployment has been retested end to end. These are all the playbooks available so far.

| Step  | Target                                   | What it does                                                           |
|-------|------------------------------------------|------------------------------------------------------------------------|
| 1     | `hypervisor/prepare-host-kubelab.yml`    | Imports hypervisor preflight, then runs `kubelab-virt`                 |
| 2     | `hypervisor/storage-kubelab.yml`         | Runs `kubelab-storage`                                                 |
| 3     | `hypervisor/provision-vms-kubelab.yml`   | Runs `kubelab-vms`                                                     |
| 4     | `virt/wait-for-k8s-nodes.yml`            | Waits for SSH and successful cloud-init completion                     |
| 5     | `k8s/prepare-k8s-nodes.yml`              | Runs `k8s-common` and `containerd`                                     |
| 6     | `k8s/verify-k8s-prerequisites.yml`       | Checks Ubuntu, resources, disabled swap, and network interfaces        |
| 7     | `k8s/kubernetes-install.yml`             | Runs `kubeadm` package installation role                               |
| 8     | `k8s/kubernetes-config.yml`              | Runs `k8s-server` control-plane configuration, recovery and validation |
  
Execute one step at a time; inspect the recap and resolve failures before proceeding.

```bash
# From ~/gh/kubelab/ansible

ansible-playbook -i inventories/host/hosts.yml playbooks/hypervisor/prepare-host-kubelab.yml -K
ansible-playbook -i inventories/host/hosts.yml playbooks/hypervisor/storage-kubelab.yml -K
ansible-playbook -i inventories/host/hosts.yml playbooks/hypervisor/provision-vms-kubelab.yml -K
ansible-playbook -i inventories/host/hosts.yml playbooks/virt/wait-for-k8s-nodes.yml -K
ansible-playbook -i inventories/host/hosts.yml playbooks/k8s/prepare-k8s-nodes.yml -K
ansible-playbook -i inventories/host/hosts.yml playbooks/k8s/verify-k8s-prerequisites.yml -K
ansible-playbook -i inventories/host/hosts.yml playbooks/k8s/kubernetes-install.yml -K
ansible-playbook -i inventories/host/hosts.yml playbooks/k8s/kubernetes-config.yml -K
```

`-K` prompts for the privilege-escalation password. It may be unnecessary when passwordless escalation is configured. The inventory must have working SSH credentials and escalation settings. Some stages may involve reboots or network changes; inspect the role implementation before applying them to a running environment.

### Hypervisor preflight: included automatically

`hypervisor/prepare-host-kubelab.yml` begins with:

```yaml
- name: Validate host prerequisites
  ansible.builtin.import_playbook: preflight-kubelab.yml
```

Therefore, **do not need to run preflight separately** before `prepare-host-kubelab.yml`. It can be run independently for diagnostics:

```bash
ansible-playbook -i inventories/host/hosts.yml playbooks/hypervisor/preflight-kubelab.yml -K
```

Preflight checks Linux/x86_64, `/dev/kvm`, and existence of the `ubuntu-vg` LVM volume group. **Important:** this means the current hypervisor preflight assumes `ubuntu-vg` already exists; it is not a universal first-boot installer for arbitrary disks.

### VM readiness gate

`wait-for-k8s-nodes.yml` waits for SSH connectivity and `cloud-init status --wait --long` to report success. Run it after VM provisioning and before configuring the guests.

### Kubernetes prerequisites gate

`verify-k8s-prerequisites.yml` checks Ubuntu, displays CPU/RAM/kernel and network interfaces, and asserts that swap is disabled. It does not by itself prove containerd CRI functionality or complete kubeadm compatibility; those require separate checks.

### Control-plane initialization gate

`kubernetes-config.yml` targets only `k8s_servers`, **not all three VMs**. Its `k8s-server` role implements initialization-state detection, conditional recovery and validation. Do not run `kubeadm init` on worker nodes.

The most recent observed rerun of this playbook was:

```text
k8s-control-1 : ok=35 changed=0 unreachable=0 failed=0 skipped=11 rescued=0 ignored=0
```

This confirms idempotency for that observed control-plane state; it does not prove all fresh-install or failure-recovery branches are tested.

## 5. Rerunning an existing environment

Do **not** automatically rerun every provisioning playbook against an already working cluster. Choose the smallest playbook for the intended change.

| Goal                                        | Recommended action                                                       |
|---------------------------------------------|--------------------------------------------------------------------------|
| Revalidate hypervisor prerequisites         | Run `preflight-kubelab.yml`                                              |
| Recheck VM SSH/cloud-init readiness         | Run `wait-for-k8s-nodes.yml`                                             |
| Recheck node OS prerequisites               | Run `verify-k8s-prerequisites.yml`                                       |
| Revalidate or reconcile control-plane state | Run `kubernetes-config.yml`                                              |
| Modify containerd or OS prerequisites       | Review changes, then run `prepare-k8s-nodes.yml`                         |
| Change Kubernetes packages                  | Review package versions and upgrade plan before `kubernetes-install.yml` |
| Reprovision VMs or storage                  | Inspect role behavior and data preservation before proceeding            |

A safe preliminary check is:

```bash
ansible-playbook -i inventories/host/hosts.yml playbooks/k8s/kubernetes-config.yml --syntax-check
ansible-playbook -i inventories/host/hosts.yml playbooks/k8s/kubernetes-config.yml --list-tasks
```

These checks validate parsing and task selection; they **do not** establish runtime safety or predict every change. Ansible check mode may also be incomplete for command-based tasks.

## 6. Destructive operations — outside the normal sequence

**Never include these playbooks in the standard deployment pipeline.**

1. `hypervisor/kubelab-destroy-vms.yml` -- Runs `kubelab-vms-destroy`. No explicit confirmation in the playbook entry point; inspect the role before use;
2. `hypervisor/destroy-storage-kubelab.yml` --  Runs `kubelab-storage-destroy`. Requires `-e confirm_storage_destroy=true`

Storage deletion can cause permanent data loss. If deliberately tearing down an environment, destroy dependent VMs before their storage **only after** verifying backups, targets, and role behavior. The supplied playbooks do not establish that every destroy operation is reversible or safe to rerun.

For reference, the storage destroy playbook explicitly blocks execution without confirmation:

```yaml
pre_tasks:
  - name: Require explicit deletion confirmation
    ansible.builtin.assert:
      that:
        - confirm_storage_destroy | default(false) | bool
```

Do not provide the confirmation flag during ordinary deployment.

## 7. Role-to-playbook mapping

| Role                      | Invoked by                               |
|---------------------------|------------------------------------------|
| `kubelab-virt`            | `hypervisor/prepare-host-kubelab.yml`    |
| `kubelab-storage`         | `hypervisor/storage-kubelab.yml`         |
| `kubelab-vms`             | `hypervisor/provision-vms-kubelab.yml`   |
| `k8s-common`              | `k8s/prepare-k8s-nodes.yml`              |
| `containerd`              | `k8s/prepare-k8s-nodes.yml`              |
| `kubeadm`                 | `k8s/kubernetes-install.yml`             |
| `k8s-server`              | `k8s/kubernetes-config.yml`              |
| `kubelab-vms-destroy`     | `hypervisor/kubelab-destroy-vms.yml`     |
| `kubelab-storage-destroy` | `hypervisor/destroy-storage-kubelab.yml` |

`preflight-kubelab.yml`, `wait-for-k8s-nodes.yml` and `verify-k8s-prerequisites.yml` define tasks directly, rather than invoking roles in the supplied entry points.

## 8. Known limitations and follow-up improvements

1. The VM destroy entry point lacks an explicit confirmation gate; review the role and consider a guard consistent with storage destruction.
2. The current hypervisor preflight assumes `ubuntu-vg` exists; document or parameterize that prerequisite if targeting other machines.
3. Some playbooks and roles contain imperative commands; verify idempotency and safe rerun behavior per stage rather than assuming it.
4. Revisit the sequence after worker enrollment, CNI deployment and GitOps stages are implemented.

## 9. Related runbooks

- `02-kubernetes-package-installation.md` — package repository and installation troubleshooting.
- `03-kubernetes-control-plane-initialization.md` — control-plane recovery, validation and initialization-state detection.
- Planned: `04-kubernetes-worker-enrollment.md` and `05-kubernetes-networking.md`.
